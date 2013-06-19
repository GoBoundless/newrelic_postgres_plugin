#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
require 'newrelic_plugin'
require 'snmp'


module NewRelic::PostgresPlugin

  BACKEND_QUERY = <<-eos
    SELECT count(*) - ( SELECT count(*) FROM pg_stat_activity WHERE
    state <> 'idle' ) AS backends_active, ( SELECT count(*) FROM
    pg_stat_activity WHERE state = 'idle' ) AS backends_idle
    FROM pg_stat_activity;
  eos
  DATABASE_QUERY = <<-eos
    SELECT * FROM pg_stat_database;
  eos
  BGWRITER_QUERY = <<-eos
    SELECT * FROM pg_stat_bgwriter;
  eos
  INDEX_COUNT_QUERY = <<-eos
    SELECT count(1) as indexes FROM pg_class WHERE relkind = 'i';
  eos
  INDEX_HIT_RATE_QUERY = <<-eos
    SELECT
      'index hit rate' AS name,
      (sum(idx_blks_hit)) / sum(idx_blks_hit + idx_blks_read) AS ratio
    FROM pg_statio_user_indexes
    UNION ALL
    SELECT
     'cache hit rate' AS name,
      sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read)) AS ratio
    FROM pg_statio_user_tables;
  eos
  INDEX_SIZE_QUERY = <<-eos
    SELECT pg_size_pretty(sum(relpages*8192)) AS size
      FROM pg_class
      WHERE reltype = 0;
  eos

  # Register and run the agent
  def self.run
    # Register this agent.
    NewRelic::Plugin::Setup.install_agent :postgres, self

    # Launch the agent; this never returns.
    NewRelic::Plugin::Run.setup_and_run
  end


  class Agent < NewRelic::Plugin::Agent::Base
    agent_guid    'com.boundless.postgres'
    agent_version '1.0.0'
    agent_config_options :host, :port, :user, :password, :dbname, :sslmode
    agent_human_labels('Postgres') { "#{hostname}" }

    def initialize
      @previous_metrics = {}
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
      PG::Connection.new(host: host, port: port, user: user, password: password, sslmode: sslmode, dbname: dbname)
    end


    #
    # This is called on every polling cycle
    #
    def poll_cycle
      connection = self.connect

      report_backend_metrics  connection
      report_bgwriter_metrics connection
      report_database_metrics connection
      report_index_metrics    connection

    rescue => e
      $stderr.puts "#{e}: #{e.backtrace.join("\n  ")}"
    end

    def report_derived_metric(name, units, value)
      if previous_value = @previous_metrics[name]
        report_metric name, units, (value - previous_value)
      else
        report_metric name, units, 0
      end
      @previous_metrics[name] = value
    end


    def report_backend_metrics(connection)
      connection.exec(BACKEND_QUERY) do |result|
        report_metric "Backends/Active", 'queries', result[0]['backends_active']
        report_metric "Backends/Idle", 'queries', result[0]['backends_idle']
      end
    end

    def report_database_metrics(connection)
      connection.exec(DATABASE_QUERY) do |result|
        result.each do |row|
          database_name = row['datname']
          report_metric        "Database/#{database_name}/Backends",                        '', row['numbackends'].to_i
          report_derived_metric "Database/#{database_name}/Transactions/Committed",          '', row['xact_commit'].to_i
          report_derived_metric "Database/#{database_name}/Transactions/Rolled Back",        '', row['xact_rollback'].to_i
          report_derived_metric "Database/#{database_name}/Tuples/Read from Disk",           '', row['blks_read'].to_i
          report_derived_metric "Database/#{database_name}/Tuples/Read Cache Hit",           '', row['blks_hit'].to_i
          report_derived_metric "Database/#{database_name}/Tuples/Returned/From Sequential", '', row['tup_returned'].to_i
          report_derived_metric "Database/#{database_name}/Tuples/Returned/From Bitmap",     '', row['tup_fetched'].to_i
          report_derived_metric "Database/#{database_name}/Tuples/Writes/Inserts",           '', row['tup_inserted'].to_i
          report_derived_metric "Database/#{database_name}/Tuples/Writes/Updates",           '', row['tup_updated'].to_i
          report_derived_metric "Database/#{database_name}/Tuples/Writes/Deletes",           '', row['tup_deleted'].to_i
          report_derived_metric "Database/#{database_name}/Conflicts",                       '', row['conflicts'].to_i
        end
      end
    end

    def report_bgwriter_metrics(connection)
      connection.exec(BGWRITER_QUERY) do |result|
        report_derived_metric "Background Writer/Checkpoints/Scheduled", 'checkpoints', result[0]['checkpoints_timed']
        report_derived_metric "Background Writer/Checkpoints/Requested", 'checkpoints', result[0]['checkpoints_requests']
      end
    end

    def report_index_metrics(connection)
      connection.exec(INDEX_COUNT_QUERY) do |result|
        report_metric "Indexes/Total", 'indexes', result[0]['indexes']
        report_metric "Indexes/Disk Utilization", 'bytes', result[0]['size_indexes']
      end
      connection.exec(INDEX_HIT_RATE_QUERY) do |result|
        report_metric "Indexes/Hit Rate", '%', result[0]['index hit rate']
        report_metric "Indexes/Cache Hit Rate", '%', result[0]['cache hit rate']
      end
      connection.exec(INDEX_SIZE_QUERY) do |result|
        report_metric "Indexes/Size", 'bytes', result[0]['size']
      end
    end

  end
end
