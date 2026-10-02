# frozen_string_literal: true

module DcpInspect
  module Progress
    class Eta
      attr_reader :percentage, :eta, :elapsed
      def initialize( title, width, looks_like, terminal_size, options, logger )
        @title = title
        @total = 100
        @scaling = width.to_f / @total
        @left, @major, @fill, @right = looks_like.scan( /./ )
        @terminal_size = terminal_size
        @output = logger
        @start = Time.now
      end

      def update( percentage )
        @percentage = percentage
        update_eta
      end

      def update_eta
        return if @percentage == 0
        @elapsed = Time.now - @start
        @eta = @elapsed * @total / @percentage - @elapsed
      end

      def update_terminal( percentage )
        update( percentage )
        line = bar
        if @terminal_size and line.length > @terminal_size[ :columns ]
          line = ' [...] ' + line[ line.length - @terminal_size[ :columns ] + 9 .. -1 ]
        end
        @output.cr( "%s\r" % line )
      end

      def clear_terminal
        @output.cr( "%s\r" % ( ' ' * bar.size ) )
      end

      def preserve_terminal
        @output.info ''
      end

      def preserve_terminal_title_with_message( message )
        clear_terminal
        @output.debug [ @title, message ].join( ' ' )
      end

      private

      def bar
        [ @title, percentage_pad, inner_bar, tail ].join( ' ' )
      end

      def percentage_pad
        "%3s%%" % @percentage
      end

      def inner_bar
        @left + @major * ( @percentage * @scaling ).ceil + @fill * ( ( @total - @percentage ) * @scaling ).floor + @right
      end

      def tail
        [ time_string( 'ETA', @eta ), time_string( 'Elapsed', @elapsed ) ].join( ' ' )
      end

      def time_string( head, t )
        return "%s --:--:--" % head if t.nil?
        t = t.to_i; s = t % 60; m  = ( t / 60 ) % 60; h = t / 3600
        "%s %02d:%02d:%02d" % [ head, h, m, s ]
      end
    end # Eta


    # FIXME ugh, this seems clonky
  end
end
