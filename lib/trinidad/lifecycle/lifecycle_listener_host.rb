module Trinidad
  module Lifecycle
    class Host
      include Trinidad::Tomcat::LifecycleListener

      attr_reader :contexts

      def initialize(*contexts)
        @contexts = contexts
      end

      def lifecycleEvent(event)
        host = event.lifecycle
        case event.type
        when Trinidad::Tomcat::Lifecycle::BEFORE_START_EVENT
          init_monitors
        when Trinidad::Tomcat::Lifecycle::PERIODIC_EVENT
          check_monitors
        end
      end

      def init_monitors
        @contexts.each do |c|
          opts = File.exist?(c[:monitor]) ? 'r' : File::CREAT|File::TRUNC

          file = File.new(c[:monitor], opts)
          c[:mtime] = file.mtime
        end
      end

      def check_monitors
        @contexts.each do |c|
          # double check monitor, capistrano removes it temporary
          sleep(0.5) unless File.exist?(c[:monitor])
          next unless File.exist?(c[:monitor])

          if (mtime = File.mtime(c[:monitor])) > c[:mtime]
            c[:mtime] = mtime
            c[:context].reload
          end
        end
      end
    end
  end
end
