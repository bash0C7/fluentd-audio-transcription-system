# lib/fluent/plugin/in_swiftcap.rb
require 'fluent/plugin/input'
require 'json'
require 'open3'
require 'fileutils'

module Fluent
  module Plugin
    class SwiftcapInput < Fluent::Plugin::Input
      Fluent::Plugin.register_input('swiftcap', self)

      helpers :thread

      config_param :swiftcap_bin, :string
      config_param :spool_dir, :string
      config_param :locale, :string, default: 'ja-JP'
      config_param :socket_path, :string
      config_param :ready_timeout, :integer, default: 30

      ALLOWED_STREAMS = %w[quick final sound state].freeze
      SHUTDOWN_GRACE_SEC = 15

      def configure(conf)
        super
        FileUtils.mkdir_p(@spool_dir)
      end

      def start
        super
        env = {
          'SWIFTCAP_SPOOL' => @spool_dir,
          'SWIFTCAP_LOCALE' => @locale,
          'SWIFTCAP_SOCKET_PATH' => @socket_path
        }
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(env, @swiftcap_bin)
        @stdin.close

        @ready_queue = Queue.new
        thread_create(:swiftcap_stdout) { read_stdout_loop }
        thread_create(:swiftcap_stderr) { read_stderr_loop }

        ready = nil
        deadline = Time.now + @ready_timeout
        while Time.now < deadline
          begin
            ready = @ready_queue.pop(true)
            break
          rescue ThreadError
            sleep 0.05
          end
        end
        unless ready == :ready
          stop_child
          raise "swiftcap did not emit swiftcap_ready within #{@ready_timeout}s"
        end
        log.info "swiftcap ready (pid=#{@wait_thread.pid})"
      end

      def shutdown
        stop_child
        super
      end

      private

      def read_stdout_loop
        @stdout.each_line do |line|
          next if line.strip.empty?
          handle_stdout_line(line)
        end
      rescue IOError
        # pipe closed during shutdown
      end

      def handle_stdout_line(line)
        record = JSON.parse(line)
        stream = record.delete('stream')
        unless ALLOWED_STREAMS.include?(stream)
          log.warn "in_swiftcap: unknown or missing stream field: #{line.strip}"
          return
        end
        if stream == 'state' && record['kind'] == 'swiftcap_ready'
          @ready_queue << :ready
        end
        time = (record['ts'] || Time.now.to_f).to_f
        router.emit("audio.#{stream}", Fluent::EventTime.from_time(Time.at(time)), record)
      rescue JSON::ParserError => e
        log.warn "in_swiftcap: bad JSON line: #{e.message}: #{line.strip}"
      end

      def read_stderr_loop
        @stderr.each_line do |line|
          log.warn "swiftcap[stderr]: #{line.chomp}"
        end
      rescue IOError
        # ignore
      end

      def stop_child
        return unless @wait_thread
        pid = @wait_thread.pid
        return unless pid && pid > 0
        begin
          Process.kill('TERM', pid)
        rescue Errno::ESRCH
          return
        end
        deadline = Time.now + SHUTDOWN_GRACE_SEC
        until Time.now > deadline
          break unless process_alive?(pid)
          sleep 0.2
        end
        if process_alive?(pid)
          log.warn "swiftcap did not exit within #{SHUTDOWN_GRACE_SEC}s; sending SIGKILL (pid=#{pid})"
          Process.kill('KILL', pid) rescue nil
        end
        @wait_thread.join rescue nil
        File.delete(@socket_path) if File.exist?(@socket_path)
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end
    end
  end
end
