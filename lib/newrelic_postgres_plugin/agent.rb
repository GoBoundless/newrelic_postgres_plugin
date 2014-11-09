module NewRelic::PostgresPlugin

  # Register and run the agent
  def self.run
    # Register this agent.
    NewRelic::Plugin::Setup.install_agent :postgres, self

    # Launch the agent; this never returns.
    NewRelic::Plugin::Run.setup_and_run
  end


  class Agent < NewRelic::Plugin::Agent::Base

    agent_guid    'com.boundless.postgres'
    agent_version NewRelic::PostgresPlugin::VERSION
    agent_config_options :host, :port, :user, :password, :dbname, :sslmode, :label
    agent_human_labels('Postgres') { "#{label || host}" }

    def initialize(*args)
      @previous_metrics = {}
      @previous_result_for_query ||= {}
      super
    end

    #
    # Required, but not used
    #
    def setup_metrics
    end

    #
    # You do not have to specify the postgres port in the yaml if you don't want to.
    #
    def port
      @port || 5432
    end

    #
    # Get a connection to postgres
    #
    def connect
      PG::Connection.new(:host => host, :port => port, :user => user, :password => password, :sslmode => sslmode, :dbname => dbname)
    end

    #
    # Returns true if we're talking to Postgres version >= 9.2
    #
    def nine_two?
      @connection.server_version >= 90200
    end

    #
    # This is called on every polling cycle
    #
    def poll_cycle
      @connection = self.connect

      report_metrics

    rescue => e
      $stderr.puts "#{e}: #{e.backtrace.join("\n  ")}"
    ensure
      @connection.finish if @connection
    end

    def report_metrics
      @connection.exec(backend_query) do |result|
        report_metric "Backends/Active", 'connections', result[0]['backends_active']
        report_metric "Backends/Idle",   'connections', result[0]['backends_idle']
      end
      @connection.exec(database_query) do |result|
        result.each do |row|
          report_metric         "Database/Backends",                 '', row['numbackends'].to_i
          report_derived_metric "Database/Transactions/Committed",   'transactions', row['xact_commit'].to_i
          report_derived_metric "Database/Transactions/Rolled Back", 'transactions', row['xact_rollback'].to_i

          report_derived_metric "Database/Rows/Selected", 'rows', row['tup_returned'].to_i + row['tup_fetched'].to_i
          report_derived_metric "Database/Rows/Inserted", 'rows', row['tup_inserted'].to_i
          report_derived_metric "Database/Rows/Updated",  'rows', row['tup_updated'].to_i
          report_derived_metric "Database/Rows/Deleted",  'rows', row['tup_deleted'].to_i

        end
      end
      @connection.exec(index_count_query) do |result|
        report_metric "Database/Indexes/Count", 'indexes', result[0]['indexes'].to_i
      end
      @connection.exec(index_size_query) do |result|
        report_metric "Database/Indexes/Size", 'bytes', result[0]['size'].to_i
      end
      @connection.exec(bgwriter_query) do |result|
        report_derived_metric "Background Writer/Checkpoints/Scheduled", 'checkpoints', result[0]['checkpoints_timed'].to_i
        report_derived_metric "Background Writer/Checkpoints/Requested", 'checkpoints', result[0]['checkpoints_requests'].to_i
      end
      report_metric "Alerts/Index Miss Ratio", '%', calculate_miss_ratio(%Q{SELECT SUM(idx_blks_hit) AS hits, SUM(idx_blks_read) AS reads FROM pg_statio_user_indexes})
      report_metric "Alerts/Cache Miss Ratio", '%', calculate_miss_ratio(%Q{SELECT SUM(heap_blks_hit) AS hits, SUM(heap_blks_read) AS reads FROM pg_statio_user_tables})

      # This is dependent on the pg_stat_statements being loaded, and assumes that pg_stat_statements.max has been set sufficiently high that most queries will be recorded. If your application typically generates more than 1000 distinct query plans per sampling interval, you're going to have a bad time.
      if extension_loaded? "pg_stat_statements"
        @connection.exec("SELECT SUM(calls) FROM pg_stat_statements") do |result|
          report_derived_metric "Database/Statements", '', result[0]["sum"].to_i
        end
      else
        puts "pg_stat_statements is not loaded; no Database/Statements metric will be reported."
      end
    end

    private

      def extension_loaded?(extname)
        @connection.exec("SELECT count(*) FROM pg_extension WHERE extname = '#{extname}'") do |result|
          result[0]["count"] == "1"
        end
      end

      def report_derived_metric(name, units, value)
        if previous_value = @previous_metrics[name]
          report_metric name, units, (value - previous_value)
        else
          report_metric name, units, 0
        end
        @previous_metrics[name] = value
      end

      # This assumes the query returns a single row with two columns: hits and reads.
      def calculate_miss_ratio(query)
        sample = @connection.exec(query)[0]
        sample.each { |key,value| sample[key] = value.to_i }
        miss_ratio = if check_samples(@previous_result_for_query[query], sample)

          hits = sample["hits"] - @previous_result_for_query[query]["hits"]
          reads = sample["reads"] - @previous_result_for_query[query]["reads"]
          
          if (hits + reads) == 0
            0.0
          else
            reads.to_f / (hits + reads) * 100.0
          end
        else
          0.0
        end
      
        @previous_result_for_query[query] = sample
        return miss_ratio
      end
 
      # Check if we don't have a time dimension yet or metrics have decreased in value.
      def check_samples(last, current)
        return false if last.nil? # First sample?
        return false unless current.find { |k,v| last[k] > v }.nil? # Values have gone down?
        return true
      end

      def backend_query
        %Q(
          SELECT ( SELECT count(*) FROM pg_stat_activity WHERE
            #{
              if nine_two?
                "state <> 'idle'"
              else
                "current_query <> '<IDLE>'"
              end
            }
          ) AS backends_active, ( SELECT count(*) FROM pg_stat_activity WHERE
            #{
              if nine_two?
                "state = 'idle'"
              else
                "current_query = '<IDLE>'"
              end
            }
          ) AS backends_idle FROM pg_stat_activity;
        )
      end

      def database_query
        "SELECT * FROM pg_stat_database WHERE datname='#{dbname}';"
      end

      def bgwriter_query
        "SELECT * FROM pg_stat_bgwriter;"
      end

      def index_count_query
        "SELECT count(1) as indexes FROM pg_class WHERE relkind = 'i';"
      end

      def index_size_query
        "SELECT sum(relpages::bigint*8192) AS size FROM pg_class WHERE reltype = 0;"
      end

  end

end
