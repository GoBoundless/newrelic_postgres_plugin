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

    def initialize name, agent_info, options={}
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
          database_name = row['datname']
          if database_name == dbname
            report_metric         "Database/Backends",                        '', row['numbackends'].to_i
            report_derived_metric "Database/Transactions/Committed",          '', row['xact_commit'].to_i
            report_derived_metric "Database/Transactions/Rolled Back",        '', row['xact_rollback'].to_i
            report_derived_metric "Database/Tuples/Read from Disk",           '', row['blks_read'].to_i
            report_derived_metric "Database/Tuples/Read Cache Hit",           '', row['blks_hit'].to_i
            report_derived_metric "Database/Tuples/Returned/From Sequential", '', row['tup_returned'].to_i
            report_derived_metric "Database/Tuples/Returned/From Bitmap",     '', row['tup_fetched'].to_i
            report_derived_metric "Database/Tuples/Writes/Inserts",           '', row['tup_inserted'].to_i
            report_derived_metric "Database/Tuples/Writes/Updates",           '', row['tup_updated'].to_i
            report_derived_metric "Database/Tuples/Writes/Deletes",           '', row['tup_deleted'].to_i
            report_derived_metric "Database/Conflicts",                       '', row['conflicts'].to_i
          end
        end
      end
    end

    def report_bgwriter_metrics
      @connection.exec(bgwriter_query) do |result|
        report_derived_metric "Background Writer/Checkpoints/Scheduled", 'checkpoints', result[0]['checkpoints_timed'].to_i
        report_derived_metric "Background Writer/Checkpoints/Requested", 'checkpoints', result[0]['checkpoints_requests'].to_i
      end
    end

    def report_index_metrics
      @connection.exec(index_count_query) do |result|
        report_metric "Indexes/Number of Indexes", 'indexes', result[0]['indexes'].to_i
      end
      @connection.exec(index_hit_rate_query) do |result|
        report_metric "Indexes/Index Hit Rate", '%', result[0]['ratio'].to_f * 100.0
        report_metric "Indexes/Cache Hit Rate", '%', result[1]['ratio'].to_f * 100.0
      end
      @connection.exec(index_size_query) do |result|
        report_metric "Indexes/Size on Disk", 'bytes', result[0]['size'].to_f
      end
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
      "SELECT * FROM pg_stat_database;"
    end

    def bgwriter_query
      "SELECT * FROM pg_stat_bgwriter;"
    end

    def index_count_query
      "SELECT count(1) as indexes FROM pg_class WHERE relkind = 'i';"
    end

    def index_hit_rate_query
      %Q(
        SELECT
          'index hit rate' AS name,
          (sum(idx_blks_hit)) / sum(idx_blks_hit + idx_blks_read) AS ratio
        FROM pg_statio_user_indexes
        UNION ALL
        SELECT
         'cache hit rate' AS name,
          sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read)) AS ratio
        FROM pg_statio_user_tables;
      )
    end

    def index_size_query
      "SELECT sum(relpages*8192) AS size FROM pg_class WHERE reltype = 0;"
    end

  end
end
