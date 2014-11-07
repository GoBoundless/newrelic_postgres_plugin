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

      report_backend_metrics
      report_bgwriter_metrics
      report_database_metrics
      report_index_metrics
      report_cache_metrics
      report_qps_metrics

    rescue => e
      $stderr.puts "#{e}: #{e.backtrace.join("\n  ")}"
    ensure
      @connection.finish if @connection
    end

    def report_derived_metric(name, units, value)
      if previous_value = @previous_metrics[name]
        report_metric name, units, (value - previous_value)
      else
        report_metric name, units, 0
      end
      @previous_metrics[name] = value
    end

    def report_backend_metrics
      @connection.exec(backend_query) do |result|
        report_metric "Backends/Active", 'connections', result[0]['backends_active']
        report_metric "Backends/Idle",   'connections', result[0]['backends_idle']
      end
    end

    def report_database_metrics
      @connection.exec(database_query) do |result|
        result.each do |row|
          report_metric         "Database/Backends",                        '', row['numbackends'].to_i
          report_derived_metric "Database/Transactions/Committed",          '', row['xact_commit'].to_i
          report_derived_metric "Database/Transactions/Rolled Back",        '', row['xact_rollback'].to_i
          report_derived_metric "Database/Tuples/Returned/From Sequential", '', row['tup_returned'].to_i
          report_derived_metric "Database/Tuples/Returned/From Bitmap",     '', row['tup_fetched'].to_i
          report_derived_metric "Database/Tuples/Writes/Inserts",           '', row['tup_inserted'].to_i
          report_derived_metric "Database/Tuples/Writes/Updates",           '', row['tup_updated'].to_i
          report_derived_metric "Database/Tuples/Writes/Deletes",           '', row['tup_deleted'].to_i
          report_derived_metric "Database/Conflicts",                       '', row['conflicts'].to_i
        end
      end
      @connection.exec(index_count_query) do |result|
        report_metric "Database/Indexes/Count", 'indexes', result[0]['indexes'].to_i
      end
      @connection.exec(index_size_query) do |result|
        report_metric "Database/Indexes/Size", 'bytes', result[0]['size'].to_i
      end
    end

    def report_bgwriter_metrics
      @connection.exec(bgwriter_query) do |result|
        report_derived_metric "Background Writer/Checkpoints/Scheduled", 'checkpoints', result[0]['checkpoints_timed'].to_i
        report_derived_metric "Background Writer/Checkpoints/Requested", 'checkpoints', result[0]['checkpoints_requests'].to_i
      end
    end

    def report_index_metrics
      report_metric "Indexes/Miss Ratio", '%', calculate_miss_ratio(%Q{SELECT SUM(idx_blks_hit) AS hits, SUM(idx_blks_read) AS reads FROM pg_statio_user_indexes})
    end

    def report_cache_metrics
      report_metric "Cache/Miss Ratio", '%', calculate_miss_ratio(%Q{SELECT SUM(heap_blks_hit) AS hits, SUM(heap_blks_read) AS reads FROM pg_statio_user_tables})
    end

    def report_qps_metrics
      report_derived_metric "Database/Queries/Count", '', @connection.exec("SELECT SUM(calls) FROM pg_stat_statements")[0]["sum"].to_i
    end

    private 

      # This assumes the query returns a single row with two columns: hits and reads.
      def calculate_miss_ratio(query)
        sample = @connection.exec(query)[0]
        sample.each { |k,v| sample[k] = v.to_i }
        @previous_result_for_query ||= {}
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
