# frozen_string_literal: true

require "io/console"

module DcpInspect
  module UI
    DCP_OK = 0
    APP_NAME = 'dcp_inspect'
    APP_VERSION = "v#{DcpInspect::VERSION}"
    RUBY_VERSION_PLATFORM = [RUBY_ENGINE, RUBY_VERSION, RUBY_PLATFORM].join(' ')
    AssetMap = DcpInspect::Model::AssetMap
    PackingList = DcpInspect::Model::PackingList
    CompositionPlaylist = DcpInspect::Model::CompositionPlaylist
    ReelAsset = DcpInspect::Model::ReelAsset
    DcpAsset = DcpInspect::Model::DcpAsset

    class DLogger
      attr_reader :is_quiet, :prints_dev, :prints_errors, :prints_hints, :prints_siginfo, :prints_info, :prints_debug, :prints_cr, :prints_cpl, :writes_logfile, :logfile, :writes_autolog
      def initialize( prefix, options, io = $stdout )
        @prefix = prefix
        @io = io
        @full_log = ( options.logfile || options.logfile_autolog || options.logfile_append ? Array.new : nil )

        @dev, @errors, @hints, @siginfo, @info, @debug, @cr, @cpl = [ false, false, false, false, false, false, false, false ]
        options.verbosity.each do |cutout|
          case cutout
          when 'quiet'   then @is_quiet = true; break
          when 'debug'   then @dev, @errors, @hints, @siginfo, @info, @debug, @cr, @cpl = [ false, true, true, true, true, true, true, true ]; @is_quiet = false; break
          when 'dev'     then @dev, @errors, @hints, @siginfo, @info, @debug, @cr, @cpl = [ true, true, true, true, true, true, true, true ]; @is_quiet = false; break
          when 'errors'  then @errors = true
          when 'hints'   then @hints = true
          when 'siginfo' then @siginfo = true
          when 'info'    then @info = true
          when 'cpl'     then @cpl = true
          when 'trace_func'
            @dev, @errors, @hints, @siginfo, @info, @debug, @cr, @cpl = [ true, false, false, false, false, false, false, false ]; @is_quiet = false
            set_trace_func proc { |event, file, line, id, binding, classname|
              printf "%8s %s:%-2d %10s %8s\n", event, file, line, id, classname
            }
          end
        end

        @writes_logfile = true if options.logfile
        @writes_autolog = true if options.logfile_autolog
        @logfile = options.logfile
        @prints_dev, @prints_errors, @prints_hints, @prints_siginfo, @prints_info, @prints_debug, @prints_cr, @prints_cpl = @dev, @errors, @hints, @siginfo, @info, @debug, @cr, @cpl
        @color = Hash.new
        @color[ :dev ] = '32' # green
      end
      def dev( text )
        if @dev then outbound_colored( text, @color[ :dev ] ) end
      end
      def errors( text )
        if @errors then outbound( text ) end
      end
      def hints( text )
        if @hints then outbound( text ) end
      end
      def siginfo( text )
        if @siginfo then outbound( text ) end
      end
      def info( text )
        if @info then outbound( text ) end
      end
      def debug( text )
        if @debug then outbound( text ) end
      end
      def cpl( text )
        if @cpl then outbound( text ) end
      end
      def cr( text )
        # don't go to @full_log here
        carriage_return( text ) if @cr
      end
      def outbound( text )
        @io.printf "%s %s\n", @prefix, text
        @full_log << text if @full_log
      end
      def outbound_colored( text, color )
        printf "%s %s\n", @prefix, colored( text, color )
      end
      def colored( text, color )
        "\033[#{ color }m#{ text }\033[0m"
      end
      def to_console( text ) @io.printf "%s %s\n", @prefix, text end
      def carriage_return( text ) @io.printf "%s %s\r", @prefix, text end
      def full_log_blob
        @full_log.join( "\n" ) + "\n"
      end
    end


    module TFSColor
      RESET = "\033[0m"
      COLORS = {
        :border => '38;5;244',
        :muted => '38;5;245',
        :title => '38;5;81',
        :ok => '38;5;76',
        :warn => '38;5;214',
        :error => '38;5;203',
        :info => '38;5;117',
        :accent => '38;5;45',
        :dim => '2',
        :reverse => '7'
      }

      def colorize( text, role )
        return text unless @color_enabled
        code = COLORS[ role ]
        return text unless code

        "\033[#{ code }m#{ text }#{ RESET }"
      end
    end


    class TFSRenderer
      include TFSColor

      ANSI_RE = /\e\[[0-9;?]*[ -\/]*[@-~]/

      attr_reader :active

      class CollapsibleState
        attr_accessor :compact_mode, :selected_index
        attr_reader :expanded, :row_offsets

        def initialize
          @expanded = {}
          @row_offsets = {}
          @selected_index = 0
          @compact_mode = false
        end

        def selected_item( items )
          return nil if items.empty?

          clamp_selection!( items.size )
          items[ @selected_index ]
        end

        def move_selection( items, amount )
          return nil if items.empty?

          @selected_index = ( @selected_index + amount ).clamp( 0, items.size - 1 )
          items[ @selected_index ]
        end

        def expanded?( key )
          @expanded[ key ] == true
        end

        def toggle( key )
          @expanded[ key ] = ! expanded?( key )
        end

        def reset_row_offsets
          @row_offsets = {}
        end

        def set_row_offset( key, offset )
          @row_offsets[ key ] = offset
        end

        def row_offset( key )
          @row_offsets[ key ]
        end

        def clamp_selection!( count )
          @selected_index = @selected_index.clamp( 0, [ count - 1, 0 ].max )
        end
      end

      def initialize( options )
        @options = options
        @run = nil
        @root_path = nil
        @active = false
        @color_enabled = STDOUT.tty? && ! ENV[ 'NO_COLOR' ]
        @started_at = Time.now
        @finished_at = nil
        @exit_code = nil
        @phase = 'Starting'
        @activity = 'Preparing inspection'
        @progress = nil
        @hash_progress = nil
        @audio_progress = nil
        @current_hash_asset = nil
        @current_subject = nil
        @recent_package_paths = []
        @recent_composition_ids = []
        @diagnostics = []
        @summary = []
        @last_frame = []
        @last_size = nil
        @last_render_at = Time.at( 0 )
        @render_interval = 0.08
        @render_mutex = Mutex.new
        @focusable_panels = [ :package_tree, :compositions, :findings ]
        @focused_panel_index = 0
        @panel_scroll_offsets = Hash.new( 0 )
        @panel_cursor_rows = {}
        @panel_selected_rows = Hash.new( 0 )
        @panel_row_actions = Hash.new { |hash, key| hash[ key ] = [] }
        @collapsed_assetmaps = {}
        @collapsible_states = Hash.new { |hash, key| hash[ key ] = CollapsibleState.new }
        @selected_am_index = 0
        @confirm_quit = false
        @cancel_requested = false
        @quit_requested = false
        @input_closed = false
        @input_thread = nil
      end

      def start
        return unless STDOUT.tty?

        @active = true
        STDOUT.write "\033[?1049h\033[?25l\033[2J\033[H"
        start_input_thread
        render( true )
      end

      def stop
        return unless @active

        @active = false
        stop_input_thread
        STDOUT.write "\033[?25h\033[?1049l"
        STDOUT.flush
      end

      def attach_run( run, root_path = nil )
        @run = run
        @root_path = root_path || run.root_path
        run.renderer = self if run.respond_to?( :renderer= )
        @phase = 'Discovery'
        @activity = "Searching AssetMaps at #{ @root_path }"
        render( true )
      end

      def model_event( event )
        @current_subject = event.subject
        remember_current_panel_items
        force_render = false
        case event.kind
        when :assetmap
          @phase = 'Discovery'
        when :packing_list
          @phase = 'PackingList'
        when :composition, :reel_asset
          @phase = 'Composition'
        when :asset
          if event.subject.respond_to?( :hash_status ) && event.subject.hash_status == 'checking'
            @phase = 'Hash checks'
            @hash_progress = nil unless @current_hash_asset == event.subject
            @current_hash_asset = event.subject
            @activity = "Hashing asset #{ short_id( event.subject.id ) }"
            force_render = true
          end
        when :check
          @phase = check_phase( event.data[ :kind ] )
          clear_current_hash_asset( event.subject )
        end
        render( force_render )
      end

      def activity( text )
        clean = clean_text( text ).strip
        return if clean.empty?

        @activity = clean
        @phase = activity_phase( clean ) || @phase
        if clean =~ /Audio analysis: Done/
          @audio_progress = nil
          @progress = nil
        end
        render
      end

      def progress( text )
        clean = clean_text( text ).strip
        return if clean.empty?

        @progress = clean
        @hash_progress = parse_hash_progress( clean ) || @hash_progress
        @audio_progress = parse_audio_progress( clean ) || @audio_progress
        render
      end

      def diagnostic( level, text )
        # Inspection findings are authoritative when attached. Logging the same
        # error during a check and again in the final report must not count twice.
        return render if @inspection_findings && @inspection_findings.key?( level )

        clean = clean_text( text ).strip
        return if clean.empty?

        @diagnostics << { :level => level, :text => clean, :time => Time.now }
        render
      end

      def track_findings( errors:, hints:, siginfo: )
        # Keep the live arrays: the engine appends to these throughout inspection,
        # independently of verbosity or whether a diagnostic was logged yet.
        @inspection_findings = { :error => errors, :hint => hints, :siginfo => siginfo }
        render
      end

      def final_summary( info )
        @summary = Array( info ).map { |line| clean_text( line ).strip }.reject { |line| line.empty? }
        render( true )
      end

      def finish( exit_code )
        @confirm_quit = false
        @exit_code = exit_code
        @finished_at = Time.now
        @phase = exit_code == DCP_OK ? 'Complete' : 'Complete with findings'
        @activity = exit_code == DCP_OK ? 'Inspection complete' : 'Inspection complete; review findings'
        render( true )
      end

      def wait_for_quit
        return unless @active
        return unless STDIN.tty?

        render( true )
        sleep 0.05 until @quit_requested || @input_closed || ! @active
      end

      def build_frame
        height, terminal_width = console_size
        height = [ height, 1 ].max
        width = [ terminal_width - 1, 1 ].max
        return compact_frame(height, width) if height < (@finished_at ? 12 : 19) || width < 50

        lines = []
        lines.concat header_lines( width )
        lines.concat now_panel( width ) unless @finished_at

        body_height = [ height - lines.size - 1, 0 ].max
        max_panel_height = [ ( height * 0.30 ).floor, 3 ].max
        package_height, composition_height, summary_height = vertical_panel_heights( body_height, max_panel_height )

        package_body_height = [ package_height - 2, 1 ].max
        composition_body_height = [ composition_height - 2, 1 ].max
        lines.concat panel( 'Package Tree', structure_lines( package_body_height, [ width - 2, 1 ].max ), width, package_height, :package_tree )
        lines.concat panel( 'Compositions', composition_lines( composition_body_height, [ width - 2, 1 ].max ), width, composition_height, :compositions )
        lines.concat panel( 'Findings', findings_lines( [width - 2, 1].max ), width, summary_height, :findings )

        lines = lines.first( height - 1 )
        lines << fit_line( '', width ) while lines.size < height - 1
        lines << (@finished_at ? 'Press q to leave dashboard | Tab: panel' : 'Tab: panel | q: quit inspection')
        lines << fit_line( '', width ) while lines.size < height
        lines.map { |line| fit_line( line, width ) }
      end

      private

      # On small terminals, dedicate the body to the selected panel. Tab still
      # reaches every panel instead of silently dropping the lower panels.
      def compact_frame(height, width)
        names = { package_tree: 'Package Tree', compositions: 'Compositions', findings: 'Findings' }
        title = "#{names.fetch(focused_panel)} (#{@focused_panel_index + 1}/3) Tab: next"
        return [fit_line('Enlarge terminal (3 rows minimum)', width)] * height if height < 3

        lines = [fit_line(title, width)]
        lines << fit_line("#{@phase}: #{@activity}", width) if height >= 6
        available = height - lines.size - 1
        content = case focused_panel
        when :package_tree then structure_lines(available, width)
        when :compositions then composition_lines(available, width)
        else findings_lines(width)
        end
        sync_findings_selection
        offset = panel_scroll_offset(focused_panel, content.size, available)
        lines.concat fit_lines(content, width, available, offset, false)
        lines << fit_line('', width) while lines.size < height - 1
        lines << fit_line(@finished_at ? 'Press q to leave dashboard' : 'q: quit inspection', width)
        lines
      end

      def safe_frame_width
        [ console_size[ 1 ] - 1, 1 ].max
      end

      def vertical_panel_heights( body_height, max_panel_height )
        return [ 0, 0, 0 ] if body_height <= 0

        min_panel = 3
        panels = [ 0, 0, 0 ]
        if body_height >= min_panel * 3
          panels[ 0 ] = [ max_panel_height, body_height - ( min_panel * 2 ) ].min
          panels[ 0 ] = [ panels[ 0 ], min_panel ].max
          panels[ 1 ] = [ max_panel_height, body_height - panels[ 0 ] - min_panel ].min
          panels[ 1 ] = [ panels[ 1 ], min_panel ].max
          panels[ 2 ] = body_height - panels[ 0 ] - panels[ 1 ]
        else
          remaining = body_height
          3.times do |idx|
            break if remaining < min_panel

            panels[ idx ] = idx == 2 ? remaining : [ max_panel_height, remaining ].min
            remaining -= panels[ idx ]
          end
        end
        panels
      end

      def start_input_thread
        @input_io = IO.console || STDIN
        return unless @input_io && @input_io.tty?
        return if @input_thread

        @input_thread = Thread.new do
          begin
            if @input_io.respond_to?( :cbreak )
              @input_io.cbreak { input_loop }
            else
              @input_io.raw { input_loop }
            end
          rescue IOError, SystemCallError
            @input_closed = true
          end
          @input_closed = true
        end
      end

      def input_loop
        while @active
          ready = IO.select( [ @input_io ], nil, nil, 0.1 )
          render( true ) if @last_size != console_size
          next unless ready

          key = @input_io.read_nonblock( 1, :exception => false )
          next if key.nil? || key == :wait_readable

          handle_keypress( key )
        end
      end

      def stop_input_thread
        return unless @input_thread

        @input_thread.kill
        @input_thread.join
        @input_thread = nil
      end

      def handle_keypress( key )
        if @confirm_quit
          case key
          when 'y', 'Y'
            @confirm_quit = false
            unless @cancel_requested
              @cancel_requested = true
              Process.kill('INT', Process.pid)
            end
          when 'n', 'N', "\r", "\n", "\e", 'q', 'Q'
            @confirm_quit = false
            render(true)
          when "\u0003"
            Process.kill('INT', Process.pid)
          end
          return
        end
        case key
        when "\t"
          focus_next_panel
        when "\r", "\n"
          if focused_panel == :package_tree
            toggle_selected_package_or_assetmap
          elsif focused_panel == :compositions
            toggle_selected_composition
          end
        when 'q', 'Q'
          if @finished_at
            @quit_requested = true
          elsif !@cancel_requested
            @confirm_quit = true
            render(true)
          end
        when "\u0003"
          Process.kill( 'INT', Process.pid )
        when "\e"
          handle_escape_sequence
        end
      end

      def handle_escape_sequence
        return unless @input_io && @input_io.tty?

        sequence = +''
        begin
          while ( ready = IO.select( [ @input_io ], nil, nil, 0.01 ) )
            chunk = @input_io.read_nonblock( 1, :exception => false )
            break if chunk.nil? || chunk == :wait_readable

            sequence << chunk
            break if sequence.match?( /\A\[[0-9;]*[A-Za-z~]\z/ ) || sequence.size >= 8
          end
        rescue IO::WaitReadable, EOFError
        end
        case sequence
        when '[Z'
          focus_previous_panel
        when '[A'
          navigate_focused_panel( -1 )
        when '[B'
          navigate_focused_panel( 1 )
        when '[5', '[5~'
          navigate_focused_panel( -5 )
        when '[6', '[6~'
          navigate_focused_panel( 5 )
        end
      end

      def focus_next_panel
        @focused_panel_index = ( @focused_panel_index + 1 ) % @focusable_panels.size
        render( true )
      end

      def focus_previous_panel
        @focused_panel_index = ( @focused_panel_index - 1 ) % @focusable_panels.size
        render( true )
      end

      def focused_panel
        @focusable_panels[ @focused_panel_index ]
      end

      def scroll_focused_panel( amount )
        panel = focused_panel
        @panel_scroll_offsets[ panel ] = [ @panel_scroll_offsets[ panel ].to_i + amount, 0 ].max
        render( true )
      end

      def navigate_focused_panel( amount )
        if focused_panel == :package_tree && collapsible_compact?( :package_tree )
          move_panel_row_selection( :package_tree, amount )
        elsif focused_panel == :compositions && collapsible_compact?( :compositions )
          move_panel_row_selection( :compositions, amount )
        else
          scroll_focused_panel( amount )
        end
      end

      def toggle_selected_composition
        toggle_selected_panel_row( :compositions )
        render( true )
      end

      def select_previous_assetmap
        assetmaps = visible_assetmaps
        return if assetmaps.empty?

        @selected_am_index = ( @selected_am_index - 1 ) % assetmaps.size
        render( true )
      end

      def select_next_assetmap
        assetmaps = visible_assetmaps
        return if assetmaps.empty?

        @selected_am_index = ( @selected_am_index + 1 ) % assetmaps.size
        render( true )
      end

      def toggle_selected_package_or_assetmap
        if collapsible_compact?( :package_tree )
          toggle_selected_package
        else
          toggle_selected_assetmap
        end
      end

      def toggle_selected_package
        toggle_selected_panel_row( :package_tree )
        render( true )
      end

      def toggle_selected_assetmap
        assetmaps = visible_assetmaps
        return if assetmaps.empty?

        @selected_am_index = @selected_am_index.clamp( 0, assetmaps.size - 1 )
        am = assetmaps[ @selected_am_index ]
        @collapsed_assetmaps[ am.id ] = assetmap_open?( am ) ? true : false
        render( true )
      end

      def collapsible_state( panel_key )
        @collapsible_states[ panel_key ]
      end

      def collapsible_compact?( panel_key )
        collapsible_state( panel_key ).compact_mode
      end

      def navigate_collapsible_section( panel_key, items, amount )
        state = collapsible_state( panel_key )
        selected = state.move_selection( items, amount )
        if selected
          row = state.row_offset( yield( selected ) )
          @panel_selected_rows[ panel_key ] = row if row
        end
        render( true )
      end

      def move_panel_row_selection( panel_key, amount )
        actions = @panel_row_actions[ panel_key ]
        max_index = [ actions.size - 1, 0 ].max
        @panel_selected_rows[ panel_key ] = ( @panel_selected_rows[ panel_key ].to_i + amount ).clamp( 0, max_index )
        render( true )
      end

      def toggle_selected_panel_row( panel_key )
        action = @panel_row_actions[ panel_key ][ @panel_selected_rows[ panel_key ].to_i ]
        return unless action

        case action[ :toggle ]
        when :collapsible
          collapsible_state( panel_key ).toggle( action[ :key ] ) if action[ :key ]
        when :assetmap
          am = action[ :subject ]
          @collapsed_assetmaps[ am.id ] = assetmap_open?( am ) ? true : false if am
        end
      end

      def toggle_collapsible_section( panel_key, items )
        return unless collapsible_compact?( panel_key )

        state = collapsible_state( panel_key )
        selected = state.selected_item( items )
        state.toggle( yield( selected ) ) if selected
      end

      def selected_collapsible_item?( panel_key, items, item )
        collapsible_state( panel_key ).selected_item( items ) == item
      end

      def collapsible_expanded?( panel_key, key )
        collapsible_state( panel_key ).expanded?( key )
      end

      def reset_panel_rows( panel_key )
        @panel_row_actions[ panel_key ] = []
      end

      def selected_panel_row?( panel_key, row )
        focused_panel == panel_key && @panel_selected_rows[ panel_key ].to_i == row
      end

      def remember_panel_row( panel_key, action = {} )
        @panel_row_actions[ panel_key ] << action
        @panel_row_actions[ panel_key ].size - 1
      end

      def clamp_panel_row_selection!( panel_key )
        max_index = [ @panel_row_actions[ panel_key ].size - 1, 0 ].max
        @panel_selected_rows[ panel_key ] = @panel_selected_rows[ panel_key ].to_i.clamp( 0, max_index )
      end

      def render( force = false )
        return unless @active

        @render_mutex.synchronize do
          now = Time.now
          return if ! force && now - @last_render_at < @render_interval

          frame = build_frame
          frame = quit_confirmation_frame(frame) if @confirm_quit
          size = console_size
          if @last_frame.empty? || @last_size != size
            STDOUT.write "\033[2J\033[H"
            STDOUT.write frame.join( "\r\n" )
          else
            frame.each_with_index do |line, idx|
              next if @last_frame[ idx ] == line

              STDOUT.write "\033[#{ idx + 1 };1H#{ line }\033[K"
            end
          end
          STDOUT.flush
          @last_frame = frame
          @last_size = size
          @last_render_at = now
        end
      end

      def quit_confirmation_frame(frame)
        width = safe_frame_width
        box_width = [width, 58].min
        message = 'Quit ongoing inspection?'
        choices = 'y: quit and save partial log | n/Enter/Esc: continue'
        if frame.size < 5 || box_width < 8
          rows = [fit_line('Quit? y/n', width)]
        else
          content = wrap_finding(message, box_width - 2) + wrap_finding(choices, box_width - 2)
          rows = panel('Confirm quit', content, box_width, [content.size + 2, frame.size].min)
        end
        top = [ (frame.size - rows.size) / 2, 0 ].max
        left = ' ' * [(width - box_width) / 2, 0].max
        result = frame.dup
        rows.each_with_index { |row, index| result[top + index] = fit_line(left + row, width) }
        result
      end

      def header_lines( width )
        elapsed = duration_label( ( @finished_at || Time.now ) - @started_at )
        asdcplib = 'available'
        ruby = RUBY_VERSION_PLATFORM
        status = @exit_code.nil? ? colorize( 'RUNNING', :accent ) : colorize( @exit_code == DCP_OK ? 'OK' : "EXIT #{ @exit_code }", @exit_code == DCP_OK ? :ok : :error )
        title = "#{APP_NAME} #{APP_VERSION}"
        started = @started_at.strftime( '%Y-%m-%d %H:%M:%S' )
        top = " #{ title }  asdcplib #{ asdcplib }  #{ ruby }"
        right = "#{ status }  #{ elapsed }  started #{ started }"
        metrics = [ scope_line, metric_line ].reject { |line| line.to_s.empty? }.join( '  ' )
        [
          fit_line( colorize( top, :title ) + fill_between( top, right, width ) + right, width ),
          fit_line( colorize( metrics, :muted ), width )
        ]
      end

      def fill_between( left, right, width )
        space = width - display_width( left ) - display_width( right )
        ' ' * [ space, 1 ].max
      end

      def scope_line
        return "phase #{@phase}  waiting for model" unless @run

        parts = [ "phase #{@phase}" ]
        inspected = compact_path( @run.root_path || @root_path )
        parts << "path #{ inspected.empty? ? '.' : inspected }"
        package_size = package_total_size_label
        parts << "size #{ package_size }" if package_size
        parts.join( '  ' )
      end

      def metric_line
        return '' unless @run

        hash_counts = hash_status_counts
        [
          "packages #{@run.packages.size}",
          "AM #{@run.assetmaps.size}",
          "PKL #{@run.packing_lists.size}",
          "CPL #{@run.compositions.size}",
          "assets #{@run.assets.size}",
          "hash OK #{hash_counts[ 'OK' ] || 0}",
          "skipped #{hash_counts[ 'skipped' ].to_i + hash_counts[ 'skipped by size' ].to_i}",
          "fail #{hash_counts[ 'mismatch' ].to_i + hash_counts[ 'empty' ].to_i}",
          "errors #{diagnostic_count( :error )}",
          "hints #{diagnostic_count( :hint )}",
          "siginfo #{diagnostic_count( :siginfo )}"
        ].join( '  ' )
      end

      def now_panel( width )
        current = @current_hash_asset
        lines = []
        if current
          lines << colorize( "Hashing #{ short_id( current.id ) }", :accent )
          lines.concat asset_context_lines( current )
          lines << hash_progress_line( current, [ width - 2, 1 ].max )
        else
          lines << colorize( @activity, :accent )
          if @current_subject && @current_subject.respond_to?( :id )
            lines << "Focus #{ @current_subject.class.name } #{ short_id( @current_subject.id ) }"
          else
            lines << "Focus #{ @root_path || 'pending' }"
          end
          lines << ( @audio_progress ? audio_progress_tfs_line( [ width - 2, 1 ].max ) : colorize( @progress || 'Waiting for next model update', :muted ) )
        end
        panel( 'Now', lines, width, 7 )
      end

      def parse_hash_progress( text )
        return nil unless text =~ /(?<percent>\d{1,3})%\s+\[[^\]]*\]\s+ETA\s+(?<eta>\S+)\s+Elapsed\s+(?<elapsed>\S+)/

        {
          :percent => [ Regexp.last_match( :percent ).to_i, 100 ].min,
          :eta => Regexp.last_match( :eta ),
          :elapsed => Regexp.last_match( :elapsed )
        }
      end

      def hash_progress_line( asset, width )
        progress = @hash_progress || parse_hash_progress( @progress.to_s )
        return colorize( @progress || @activity, :muted ) unless progress

        percent = progress[ :percent ].to_i.clamp( 0, 100 )
        spinner = hash_spinner
        amount = hash_progress_amount( asset, percent )
        suffix_parts = [ "#{ percent.to_s.rjust( 3 ) }%", amount, "eta #{ progress[ :eta ] }", "elapsed #{ progress[ :elapsed ] }" ].compact
        prefix = "#{ colorize( spinner, :accent ) } "
        suffix = suffix_parts.join( '  ' )
        bar_width = [ 20, width - display_width( prefix ) - display_width( suffix ) - 2 ].min

        if bar_width < 8
          compact_suffix = [ "#{ percent }%", amount ].compact.join( '  ' )
          return fit_line( "#{ prefix }#{ colorize( compact_suffix, :muted ) }", width ).rstrip
        end

        "#{ prefix }#{ progress_bar( percent, bar_width ) } #{ colorize( suffix, :muted ) }"
      end

      def parse_audio_progress( text )
        return nil unless text =~ /(?<label>.+): Audio analysis: (?<percent>\d{1,3})%\s+(?<current>\S+)\/(?<total>\S+)/

        {
          :label => Regexp.last_match( :label ),
          :percent => [ Regexp.last_match( :percent ).to_i, 100 ].min,
          :current => Regexp.last_match( :current ),
          :total => Regexp.last_match( :total )
        }
      end

      def audio_progress_tfs_line( width )
        percent = @audio_progress[ :percent ].to_i.clamp( 0, 100 )
        prefix = "#{ colorize( hash_spinner, :accent ) } "
        suffix = "#{ percent.to_s.rjust( 3 ) }%  #{ @audio_progress[ :current ] }/#{ @audio_progress[ :total ] }"
        label_width = [ width - display_width( prefix ) - 20 - display_width( suffix ) - 4, 12 ].max
        label = take_display( @audio_progress[ :label ], label_width )
        "#{ prefix }#{ colorize( label, :accent ) } #{ progress_bar( percent, 20 ) } #{ colorize( suffix, :muted ) }"
      end

      def hash_spinner
        frames = %w( ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏ )
        frames[ ( Time.now.to_f * 12 ).to_i % frames.size ]
      end

      def hash_progress_amount( asset, percent )
        total = asset.size_actual || asset.size_listed
        return nil unless total && total.to_i > 0

        done = ( total.to_i * percent / 100.0 ).round
        "#{ size_label( done ) }/#{ size_label( total ) }"
      end

      def progress_bar( percent, width )
        filled = ( width * percent / 100.0 ).floor
        filled = [ filled, width ].min
        if percent >= 100
          return colorize( '━' * width, :ok )
        end

        head = filled < width ? colorize( '╸', :accent ) : ''
        complete = colorize( '━' * filled, :accent )
        remaining = colorize( '─' * [ width - filled - ( head.empty? ? 0 : 1 ), 0 ].max, :muted )
        "#{ complete }#{ head }#{ remaining }"
      end

      def structure_lines( max_body_height = nil, width = nil )
        return [ 'Waiting for inspection run' ] unless @run
        return [ 'No packages discovered yet' ] if @run.packages.empty?

        assetmaps = visible_assetmaps
        @selected_am_index = 0 if assetmaps.empty?
        @selected_am_index = @selected_am_index.clamp( 0, assetmaps.size - 1 ) unless assetmaps.empty?
        packages = @run.packages
        package_state = collapsible_state( :package_tree )
        package_state.compact_mode = true

        compact_package_tree_lines( packages, width || 100, package_state, max_body_height )
      end

      def expanded_package_tree_lines( packages, assetmaps, width )
        lines = []
        packages.each do |pkg|
          lines << package_summary_line( pkg, false, false )
          lines.concat package_detail_lines( pkg, assetmaps, width, false )
        end
        unlinked = @run.packing_lists.values.select { |pkl| pkl.assetmap.nil? }
        if unlinked.any?
          lines << colorize( 'Unlinked PackingLists', :warn )
          unlinked.each { |pkl| lines << "  └─ PKL #{ status_token( pkl ) } #{ short_id( pkl.id ) }  #{ compact_path( pkl.path ) }" }
        end
        lines
      end

      def compact_package_tree_lines( packages, width, state, visible_size = nil )
        state.reset_row_offsets
        reset_panel_rows( :package_tree )
        @panel_cursor_rows.delete( :package_tree )
        lines = []
        packages.each do |pkg|
          state.set_row_offset( pkg.base_path, lines.size )
          row = remember_panel_row( :package_tree, :toggle => :collapsible, :key => pkg.base_path, :subject => pkg )
          selected = selected_panel_row?( :package_tree, row )
          open = package_expanded?( pkg )
          @panel_cursor_rows[ :package_tree ] = lines.size if current_package?( pkg )
          lines << focus_line( package_summary_line( pkg, open, true, selected ), selected )
          lines.concat package_detail_lines( pkg, visible_assetmaps, width, true, lines.size ) if open
        end
        clamp_panel_row_selection!( :package_tree )
        row_to_show = focused_panel == :package_tree ? @panel_selected_rows[ :package_tree ] : @panel_cursor_rows[ :package_tree ]
        ensure_panel_cursor_visible( :package_tree, row_to_show, visible_size, lines.size )
        lines
      end

      def package_summary_line( pkg, open, compact, selected = false )
        current = current_package?( pkg )
        marker = selected ? colorize( '●', :accent ) : ( current ? colorize( '▶', :accent ) : ( compact ? ' ' : colorize( '▣', :accent ) ) )
        toggle = compact ? ( open ? '▾' : '▸' ) : ''
        path = compact_path( pkg.base_path )
        "#{ marker }#{ compact ? ' ' + toggle : '' } #{ path.empty? ? '.' : path }  #{ pkg.assetmaps.size } AM"
      end

      def package_detail_lines( pkg, assetmaps, width, tree_mode, base_row = 0 )
        lines = []
        pkg.assetmaps.each do |am|
          row = remember_panel_row( :package_tree, :toggle => :assetmap, :subject => am )
          selected = tree_mode ? selected_panel_row?( :package_tree, row ) : focused_panel == :package_tree && assetmaps[ @selected_am_index ] == am
          open = assetmap_open?( am ) || assetmap_contains_current_hash?( am )
          marker = open ? '▾' : '▸'
          if tree_mode
            branch = current_package_tree_subject?( am ) ? "  ├#{ colorize( '▶', :accent )} " : '  ├─ '
            am_line = "#{ branch }#{ marker } AM  #{ status_token( am ) } #{ short_id( am.id ) }  #{ compact_path( am.path ) }  #{ am.assets.size } asset#{ plural_suffix( am.assets.size ) }"
          else
            am_marker = current_package_tree_subject?( am ) ? "#{ colorize( '▶', :accent ) } " : '  '
            am_line = "#{ am_marker }#{ marker } AM  #{ status_token( am ) } #{ short_id( am.id ) }  #{ compact_path( am.path ) }  #{ am.assets.size } asset#{ plural_suffix( am.assets.size ) }"
          end
          @panel_cursor_rows[ :package_tree ] = base_row + lines.size if current_package_tree_subject?( am )
          lines << focus_line( am_line, selected )
          next unless open

          lines.concat assetmap_asset_lines( am, width, base_row + lines.size )
        end
        lines
      end

      def package_expanded?( pkg )
        collapsible_expanded?( :package_tree, pkg.base_path )
      end

      def current_selected_package?( pkg )
        packages = @run ? @run.packages : []
        selected_collapsible_item?( :package_tree, packages, pkg )
      end

      def composition_lines( max_body_height = nil, width = nil )
        return [ 'Waiting for compositions' ] unless @run

        cpls = prioritized_compositions
        return [ 'No compositions detected yet' ] if cpls.empty?

        composition_state = collapsible_state( :compositions )
        composition_state.compact_mode = true

        compact_composition_lines( cpls, composition_state, width || 100, max_body_height )
      end

      def expanded_composition_lines( cpls, width = nil )
        lines = []
        cpls.each_with_index do |cpl, cpl_index|
          lines << '' if cpl_index > 0
          marker = current_composition?( cpl ) ? "#{ colorize( '▶', :accent ) } " : '  '
          lines << "#{ marker }#{ composition_summary_text( cpl ) }"
          lines.concat composition_detail_lines( cpl, false, width )
        end
        lines
      end

      def compact_composition_lines( cpls, state, width, visible_size = nil )
        state.reset_row_offsets
        reset_panel_rows( :compositions )
        lines = []
        cpls.each do |cpl|
          state.set_row_offset( cpl.id, lines.size )
          row = remember_panel_row( :compositions, :toggle => :collapsible, :key => cpl.id, :subject => cpl )
          selected = selected_panel_row?( :compositions, row )
          current = current_composition?( cpl )
          open = composition_expanded?( cpl )
          marker = selected ? colorize( '●', :accent ) : ( current ? colorize( '▶', :accent ) : ' ' )
          toggle = open ? '▾' : '▸'
          summary = "#{ marker } #{ toggle } #{ composition_summary_text( cpl ) }"
          lines << focus_line( summary, selected )
          lines.concat composition_detail_lines( cpl, true, width, lines.size ) if open
        end
        clamp_panel_row_selection!( :compositions )
        row_to_show = focused_panel == :compositions ? @panel_selected_rows[ :compositions ] : nil
        ensure_panel_cursor_visible( :compositions, row_to_show, visible_size, lines.size )
        lines
      end

      def composition_detail_lines( cpl, tree_mode, width = nil, base_row = 0 )
        chips = [ cpl.type, cpl.content_kind, cpl.language ].compact.reject { |v| v.to_s.empty? || v == '[Empty]' }
        complete = { pending: 'checks pending', complete: 'complete', incomplete: 'incomplete',
                     external: 'external assets required', warning: 'composition warning' }.fetch(cpl.completeness_status)
        cpl_status_line = "#{ chips.join( '  ' ) }  #{ complete }  #{ signature_schema_label( cpl ) }"
        lines = []
        add_line = lambda do |line|
          row = remember_panel_row( :compositions, :subject => cpl )
          lines << focus_line( line, selected_panel_row?( :compositions, row ) )
        end

        if cpl.reels.empty?
          if tree_mode
            add_line.call( "  ├─ #{ cpl_status_line }" )
            add_line.call( colorize( '  └─ Reels pending', :muted ) )
          else
            add_line.call( "  #{ cpl_status_line }" )
            add_line.call( colorize( '  Reels pending', :muted ) )
          end
          return lines
        end

        if tree_mode
          add_line.call( "  ├─ #{ cpl_status_line }" )
        else
          add_line.call( "  #{ cpl_status_line }" )
        end
        lines.concat composition_reel_lines( cpl, tree_mode, width )
        lines
      end

      def composition_reel_lines( cpl, tree_mode, width = nil )
        lines = []
        reels = cpl.reels.sort_by { |reel| reel.number.to_i }
        reels.each_with_index do |reel, reel_index|
          if tree_mode
            reel_connector = reel_index == reels.size - 1 ? '└' : '├'
            reel_branch = "#{ reel_connector }─"
            row = remember_panel_row( :compositions, :subject => reel )
            lines << focus_line( "  #{ reel_branch } R#{ reel.number.to_s.rjust( 2, '0' ) }", selected_panel_row?( :compositions, row ) )
            asset_prefix = reel_index == reels.size - 1 ? '     ' : '  │  '
          else
            row = remember_panel_row( :compositions, :subject => reel )
            lines << focus_line( "  R#{ reel.number.to_s.rjust( 2, '0' ) }", selected_panel_row?( :compositions, row ) )
            asset_prefix = '  │  '
          end
          reel_assets = reel.assets
          reel_assets.each_with_index do |asset, asset_index|
            duration = aligned_duration( asset.duration, asset.edit_rate )
            rate = asset.edit_rate ? format( '%6.2f', asset.edit_rate ) : '  ?.??'
            resolved = asset.resolved ? colorize( 'resolved', :ok ) : colorize( 'pending', :warn )
            connector = asset_index == reel_assets.size - 1 ? '└' : '├'
            branch = current_reel_asset?( asset ) ? "#{ connector }#{ colorize( '▶', :accent ) }" : "#{ connector }─"
            line = "#{ asset_prefix }#{ branch} #{ duration }  @#{ rate }  #{ asset.kind.to_s.ljust( 20 ) }  #{ short_id( asset.id ) }  #{ resolved }"
            line = "#{ line }  #{ audio_detail_text( asset ) }" if asset.details && ! asset.details.to_s.empty?
            continuation = "#{ asset_prefix }#{ asset_index == reel_assets.size - 1 ? '   ' : '│  ' }  "
            wrap_timeline_line( line, continuation, width ).each do |wrapped_line|
              row = remember_panel_row( :compositions, :subject => asset )
              lines << focus_line( wrapped_line, selected_panel_row?( :compositions, row ) )
            end
          end
        end
        lines
      end

      def composition_summary_text( cpl )
        "#{ colorize( short_id( cpl.id ), :info ) }  #{ cpl.title || cpl.annotation || compact_path( cpl.path ) || short_id( cpl.id ) }"
      end

      def audio_detail_text( asset )
        details = "(#{ asset.details })"
        return details unless asset.kind.to_s == 'MainSound'

        role = if asset.details.include?( '[OK]' )
                 :ok
               elsif asset.details.include?( '[WARN' )
                 :warn
               elsif asset.details.include?( '[LOW]' ) || asset.details.include?( '[LOUD]' )
                 :error
               else
                 :muted
               end
        colorize( details, role )
      end

      def wrap_timeline_line( line, continuation_prefix, width )
        return [ line ] unless width && width > display_width( continuation_prefix ) + 8
        return [ line ] if display_width( line ) <= width

        leading = line.to_s[ /\A\s*/ ] || ''
        words = line.to_s[ leading.size..-1 ].to_s.split( /\s+/ )
        lines = []
        current = leading.dup
        words.each do |word|
          candidate = current.strip.empty? ? "#{ current }#{ word }" : "#{ current } #{ word }"
          if display_width( candidate ) <= width
            current = candidate
          else
            lines << current.rstrip unless current.strip.empty?
            current = "#{ continuation_prefix }#{ word }"
          end
        end
        lines << current.rstrip unless current.strip.empty?
        lines.empty? ? [ line ] : lines
      end

      def composition_expanded?( cpl )
        collapsible_expanded?( :compositions, cpl.id )
      end

      def visible_assetmaps
        return [] unless @run

        @run.packages.flat_map { |pkg| pkg.assetmaps }
      end

      def current_package_tree_asset
        return @current_hash_asset if @current_hash_asset
        return @current_subject if @current_subject.is_a?( DcpAsset )
        return @current_subject.asset if @current_subject.is_a?( ReelAsset ) && @current_subject.asset
        return @run.assets[ @current_subject.id ] if @run && @current_subject.respond_to?( :id ) && @run.assets[ @current_subject.id ]

        nil
      end

      def current_assetmap
        return current_package_tree_asset.assetmap if current_package_tree_asset && current_package_tree_asset.assetmap
        return @current_subject if @current_subject.is_a?( AssetMap )
        return @current_subject.assetmap if @current_subject.is_a?( PackingList ) && @current_subject.assetmap
        return @current_subject.packing_lists.first.assetmap if @current_subject.is_a?( CompositionPlaylist ) && @current_subject.packing_lists.first
        return @current_subject.asset.assetmap if @current_subject.is_a?( ReelAsset ) && @current_subject.asset && @current_subject.asset.assetmap

        nil
      end

      def current_package?( pkg )
        current_am = current_assetmap
        return true if current_am && pkg.assetmaps.include?( current_am )

        false
      end

      def current_composition_ids
        return [] unless @current_subject || @current_hash_asset

        case @current_subject
        when CompositionPlaylist
          [ @current_subject.id ]
        when ReelAsset
          [ @current_subject.reel.composition.id ]
        when PackingList
          @current_subject.compositions.map { |cpl| cpl.id }
        else
          asset = current_package_tree_asset
          ids = asset ? asset.reel_references.map { |ref| ref.reel.composition.id } : []
          ids << asset.id if asset && @run && @run.compositions[ asset.id ]
          ids.uniq
        end
      end

      def current_reel_asset_ids
        return [ @current_subject.id ] if @current_subject.is_a?( ReelAsset )

        asset = current_package_tree_asset
        asset ? [ asset.id ] : []
      end

      def current_package_tree_subject?( subject )
        return false unless subject
        return true if subject == @current_subject || subject == @current_hash_asset
        return true if subject.respond_to?( :id ) && @current_subject.respond_to?( :id ) && subject.id == @current_subject.id
        return true if current_package_tree_asset && subject.respond_to?( :id ) && subject.id == current_package_tree_asset.id

        false
      end

      def current_composition?( cpl )
        current_composition_ids.include?( cpl.id )
      end

      def current_reel_asset?( reel_asset )
        current_reel_asset_ids.include?( reel_asset.id ) ||
          ( @current_hash_asset && reel_asset.asset == @current_hash_asset ) ||
          ( @current_subject.is_a?( ReelAsset ) && reel_asset == @current_subject )
      end

      def prioritize_current_assetmaps( assetmaps )
        current = current_assetmap
        assetmaps.sort_by { |am| [ current && am == current ? 0 : 1, am.path.to_s, am.id.to_s ] }
      end

      def prioritize_current_packing_lists( pkls )
        current_asset = current_package_tree_asset
        pkls.sort_by do |pkl|
          current = current_package_tree_subject?( pkl ) ||
                    ( current_asset && ( pkl.id == current_asset.id || pkl.assets.include?( current_asset ) ) )
          [ current ? 0 : 1, pkl.path.to_s, pkl.id.to_s ]
        end
      end

      def prioritize_current_compositions( cpls )
        order_by_recency( cpls, @recent_composition_ids ) { |cpl| cpl.id }
      end

      def prioritize_current_reels( reels )
        ids = current_reel_asset_ids
        reels.sort_by { |reel| [ reel.assets.any? { |asset| ids.include?( asset.id ) || current_reel_asset?( asset ) } ? 0 : 1, reel.number.to_i ] }
      end

      def prioritize_current_reel_assets( assets )
        assets.sort_by { |asset| [ current_reel_asset?( asset ) ? 0 : 1, asset.kind.to_s, asset.id.to_s ] }
      end

      def prioritize_current_assets( assets )
        current = current_package_tree_asset
        assets.sort_by { |asset| [ current && asset == current ? 0 : 1, asset_role_label( asset ), asset.assetmap_path.to_s, asset.id.to_s ] }
      end

      def package_tree_needs_collapsible?( max_body_height )
        return false unless max_body_height
        return false unless visible_assetmaps.size > 1

        expanded = []
        @run.packages.each do |pkg|
          expanded << pkg
          pkg.assetmaps.each do |am|
            expanded << am
            expanded.concat assetmap_asset_lines( am, 120 )
          end
        end
        expanded.size > max_body_height
      end

      def assetmap_open?( am )
        return ! @collapsed_assetmaps[ am.id ] if @collapsed_assetmaps.key?( am.id )

        true
      end

      def assetmap_contains_current_hash?( am )
        @current_hash_asset && @current_hash_asset.assetmap == am
      end

      def assetmap_asset_lines( am, width, base_row = 0 )
        lines = []
        pkl_assets = am.packing_lists.map { |pkl| @run.assets[ pkl.id ] }.compact
        pkl_cpl_ids = am.packing_lists.flat_map { |pkl| pkl.compositions.map { |cpl| cpl.id } }
        shown_asset_ids = []

        pkls = am.packing_lists
        pkls.each_with_index do |pkl, index|
          connector = index == pkls.size - 1 && remaining_non_pkl_assets( am, pkl_assets, pkl_cpl_ids ).empty? ? '└' : '├'
          pkl_asset = @run.assets[ pkl.id ]
          left = "  │  #{ connector }─ PKL #{ status_token( pkl ) } #{ short_id( pkl.id ) }  #{ compact_path( pkl.path ) }"
          row = remember_panel_row( :package_tree, :subject => pkl )
          selected = selected_panel_row?( :package_tree, row )
          @panel_cursor_rows[ :package_tree ] = base_row + lines.size if current_package_tree_subject?( pkl ) || current_package_tree_subject?( pkl_asset )
          lines << focus_line( package_tree_row( left, pkl_asset, width ), selected )
          shown_asset_ids << pkl.id
          pkl.compositions.each_with_index do |cpl, cpl_index|
            cpl_asset = @run.assets[ cpl.id ]
            cpl_connector = cpl_index == pkl.compositions.size - 1 ? '└' : '├'
            title = cpl.title || cpl.annotation || compact_path( cpl.path )
            left = "  │  │  #{ cpl_connector }─ CPL #{ status_token( cpl ) } #{ short_id( cpl.id ) }  #{ title }"
            row = remember_panel_row( :package_tree, :subject => cpl )
            selected = selected_panel_row?( :package_tree, row )
            @panel_cursor_rows[ :package_tree ] = base_row + lines.size if current_package_tree_subject?( cpl ) || current_package_tree_subject?( cpl_asset )
            lines << focus_line( package_tree_row( left, cpl_asset, width ), selected )
            shown_asset_ids << cpl.id
          end
        end

        remaining_assets = remaining_non_pkl_assets( am, pkl_assets, pkl_cpl_ids ).reject { |asset| shown_asset_ids.include?( asset.id ) }
        remaining_assets.each_with_index do |asset, index|
          connector = index == remaining_assets.size - 1 ? '└' : '├'
          left = "  │  #{ connector }─ #{ asset_role_label( asset ) } #{ short_id( asset.id ) }  #{ compact_path( asset.assetmap_path || asset.packing_list_path || asset.absolute_path ) }"
          row = remember_panel_row( :package_tree, :subject => asset )
          selected = selected_panel_row?( :package_tree, row )
          @panel_cursor_rows[ :package_tree ] = base_row + lines.size if current_package_tree_subject?( asset )
          lines << focus_line( package_tree_row( left, asset, width ), selected )
          shown_asset_ids << asset.id
        end

        missing_assets = am.assets.reject { |asset| shown_asset_ids.include?( asset.id ) }
        missing_assets.each do |asset|
          left = "  │  └─ Asset #{ short_id( asset.id ) }  #{ compact_path( asset.assetmap_path || asset.absolute_path ) }"
          row = remember_panel_row( :package_tree, :subject => asset )
          selected = selected_panel_row?( :package_tree, row )
          @panel_cursor_rows[ :package_tree ] = base_row + lines.size if current_package_tree_subject?( asset )
          lines << focus_line( package_tree_row( left, asset, width ), selected )
        end
        lines
      end

      def remaining_non_pkl_assets( am, pkl_assets, pkl_cpl_ids )
        pkl_asset_ids = pkl_assets.map { |asset| asset.id }
        am.assets.reject { |asset| pkl_asset_ids.include?( asset.id ) || pkl_cpl_ids.include?( asset.id ) }.sort_by { |asset| [ asset_role_label( asset ), asset.assetmap_path.to_s, asset.id.to_s ] }
      end

      def package_tree_row( left, asset, width )
        if asset && current_package_tree_subject?( asset )
          marked = left.sub( /([├└])─ / ) { "#{ Regexp.last_match( 1 ) }#{ colorize( '▶', :accent ) } " }
          left = marked == left ? "#{ colorize( '▶', :accent ) } #{ left }" : marked
        end
        return left unless asset

        right = [
          hash_state_label( asset ),
          size_label( asset.size_actual || asset.size_listed ).rjust( 9 ),
          take_display( type_label( asset.type ), 18 ).ljust( 18 )
        ].join( '  ' )
        join_left_right( left, right, width )
      end

      def join_left_right( left, right, width )
        available_left = width - display_width( right ) - 2
        if available_left > 8
          left = fit_line( left, available_left ).rstrip
          "#{ left }#{ ' ' * [ width - display_width( left ) - display_width( right ), 1 ].max }#{ right }"
        else
          "#{ left }  #{ right }"
        end
      end

      def hash_state_label( asset )
        state = asset_state( asset )
        role = case state
        when 'OK' then :ok
        when 'checking' then :accent
        when 'skipped', 'skipped by size', 'known' then :muted
        else :error
        end
        colorize( take_display( state, 15 ).rjust( 15 ), role )
      end

      def asset_role_label( asset )
        type = type_label( asset.type )
        return 'CPL' if type == 'xml' && @run.compositions[ asset.id ]
        return 'PKL' if type == 'xml' && @run.packing_lists[ asset.id ]
        return 'MXF' if type == 'mxf'

        'Asset'
      end

      def focus_line( line, selected )
        return line unless selected

        colorize( line, :reverse )
      end

      def sync_findings_selection
        return if focused_panel == :findings

        action = @panel_row_actions[focused_panel][@panel_selected_rows[focused_panel].to_i]
        subject = action && action[:subject]
        return if subject.equal?(@findings_subject)

        @findings_subject = subject
        @panel_scroll_offsets[:findings] = 0
      end

      def finding_subjects(subject)
        children = case subject
        when Model::DcpPackage then subject.assetmaps
        when Model::AssetMap then subject.packing_lists + subject.assets
        when Model::PackingList then subject.compositions + subject.assets
        when Model::CompositionPlaylist then subject.reels
        when Model::Reel then subject.assets
        when Model::ReelAsset then [subject.asset].compact
        else []
        end
        [subject, *children.flat_map { |child| finding_subjects(child) }].compact.uniq
      end

      def finding_context
        return unless @findings_subject

        subjects = finding_subjects(@findings_subject)
        tokens = subjects.flat_map do |subject|
          [:id, :absolute_path].filter_map do |field|
            value = subject.public_send(field) if subject.respond_to?(field)
            value.to_s unless value.nil? || value.to_s.empty?
          end
        end.uniq
        matcher = tokens.empty? ? nil : /(?<![[:alnum:]_-])(?:#{Regexp.union(tokens)})(?![[:alnum:]_-])/
        reels = case @findings_subject
        when Model::Reel then [@findings_subject]
        when Model::ReelAsset then [@findings_subject.reel]
        when Model::DcpAsset then @findings_subject.reel_references.map(&:reel).uniq
        else []
        end
        { subjects: subjects, matcher: matcher, reels: reels }
      end

      def related_finding?(context, text, subject = nil)
        return true if subject && context[:subjects].include?(subject)
        return true if context[:matcher]&.match?(text.to_s)

        # Many legacy diagnostics identify a reel by CPL UUID and reel number
        # rather than by the UUID of its media asset.
        context[:reels].any? do |reel|
          text.to_s.include?(reel.composition.id) &&
            text.to_s.match?(/\bReel\s+0*#{Regexp.escape(reel.number.to_s)}\b/i)
        end
      end

      def finding_selection_label
        subject = @findings_subject
        case subject
        when Model::DcpPackage then "Package #{compact_path(subject.base_path)}"
        when Model::Reel then "CPL #{short_id(subject.composition.id)} / Reel #{subject.number}"
        when Model::ReelAsset then "CPL #{short_id(subject.reel.composition.id)} / Reel #{subject.reel.number} / #{subject.kind} #{short_id(subject.id)}"
        else "#{subject.class.name.split('::').last} #{short_id(subject.id)}"
        end
      end

      def findings_lines( width = nil )
        return [ 'Waiting for checks' ] unless @run

        sync_findings_selection
        checks = @run.events.reverse.select { |event| event.kind == :check && event.data[:status] == :error }
        diagnostics = diagnostic_entries
        lines = [findings_status_line]
        context = finding_context
        if context
          related_checks, checks = checks.partition { |event| related_finding?(context, event.data[:message], event.subject) }
          related_diagnostics, diagnostics = diagnostics.partition { |entry| related_finding?(context, entry[:text]) }
          lines << colorize("Related to #{finding_selection_label}", :title)
          lines.concat related_diagnostics.map { |entry| diagnostic_line(entry) }
          lines.concat related_checks.map { |event| check_event_line(event) }
          lines << 'No findings recorded for this selection' if related_checks.empty? && related_diagnostics.empty?
          lines << ''
          lines << colorize('Other findings', :title)
        end
        notes = run_note_lines
        lines << run_note_summary(notes) if notes.any?
        if checks.any?
          lines << colorize('Failed checks', :title)
          lines.concat checks.map { |event| check_event_line(event) }
        end
        skipped = @run.events.count { |event| event.kind == :check && event.data[:status] == :skipped }
        lines << colorize("#{skipped} skipped check#{plural_suffix(skipped)}", :warn) if skipped > 0
        if diagnostics.any?
          lines << colorize('Diagnostics', :title)
          lines.concat diagnostics.map { |entry| diagnostic_line(entry) }
        end
        width ? lines.flat_map { |line| wrap_finding(line, width) } : lines
      end

      # Wrap complete messages before panel scrolling, including unbroken paths.
      def wrap_finding(line, width)
        if @finding_wrap_width != width
          @finding_wrap_width = width
          @finding_wrap_cache = {}
        end
        @finding_wrap_cache[line] ||= begin
          plain = clean_text(line).gsub(/\e\[[0-9;]*m/, '')
          color = line[/\e\[[0-9;]*m/] || ''
          rows = [+'']
          used = 0
          plain.each_char do |char|
            size = char_width(char)
            if used + size > width && !rows.last.empty?
              rows << +''
              used = 0
            end
            rows[-1] << char
            used += size
          end
          rows.map { |row| color.empty? ? row : "#{color}#{row}\e[0m" }
        end
      end

      def run_note_lines
        @summary.select do |line|
          line =~ /\A(?:Hash checks skipped|Schema checks skipped|Audio analysis skipped)/
        end
      end

      def findings_status_line
        errors = diagnostic_count( :error )
        hints = diagnostic_count( :hint )
        siginfo = diagnostic_count( :siginfo )
        role = errors > 0 ? :error : ( hints > 0 ? :warn : :ok )
        colorize( "#{ errors } error#{ plural_suffix( errors ) }  #{ hints } hint#{ plural_suffix( hints ) }  #{ siginfo } siginfo", role )
      end

      def run_note_summary( notes )
        compact = notes.map do |note|
          case note
          when /\AHash checks skipped for assets bigger than (.+)\z/
            "hash limit #{ Regexp.last_match( 1 ) }"
          when /\AHash checks skipped for (.+)\z/
            "hash skipped #{ Regexp.last_match( 1 ) }"
          when /\AAudio analysis skipped\z/
            'audio skipped'
          when /\ASchema checks skipped\z/
            'schema skipped'
          else
            note
          end
        end
        colorize( "Run notes  #{ compact.join( '  |  ' ) }", :muted )
      end

      def check_event_line( event )
        subject = event.subject.respond_to?( :id ) ? short_id( event.subject.id ) : event.subject.class.name
        status = event.data[ :status ].to_s.upcase
        role = case event.data[ :status ]
        when :ok then :ok
        when :skipped then :warn
        else :error
        end
        "#{ colorize( status.rjust( 7 ), role ) }  #{ event.data[ :kind ] }  #{ subject }  #{ event.data[ :message ] }"
      end

      def diagnostic_line( entry )
        role = case entry[ :level ]
        when :error then :error
        when :hint then :warn
        else :info
        end
        "#{ colorize( entry[ :level ].to_s.upcase.rjust( 7 ), role ) }  #{ entry[ :text ] }"
      end

      def package_total_size_label
        return nil unless @run

        sizes = @run.packing_lists.values.each_with_object( [ 0, 0 ] ) do |pkl, sums|
          next unless pkl.package_size_actual || pkl.package_size_listed

          sums[ 0 ] += pkl.package_size_actual.to_i
          sums[ 1 ] += pkl.package_size_listed.to_i
        end
        return nil if sizes[ 0 ] == 0 && sizes[ 1 ] == 0

        sizes[ 0 ] == sizes[ 1 ] ? size_label( sizes[ 0 ] ) : "#{ size_label( sizes[ 0 ] ) } listed #{ size_label( sizes[ 1 ] ) }"
      end

      def panel( title, content, width, height, focus_key = nil )
        return [] if height <= 0
        return fit_lines( content, width, height ) if width < 4 || height < 3

        inner = width - 2
        focused = focus_key && focused_panel == focus_key
        border_role = focused ? :accent : :border
        available = height - 2
        content = Array( content )
        scroll = panel_scroll_offset( focus_key, content.size, available )
        scroll_text = focused && content.size > available ? " #{ scroll + 1 }/#{ content.size } " : ''
        title_text = focused ? " ● #{ title }#{ scroll_text }" : " #{ title } "
        title_text = take_display( title_text, inner )
        top = "╭#{ title_text }#{ '─' * [ inner - display_width( title_text ), 0 ].max }╮"
        bottom = "╰#{ '─' * inner }╯"
        body = fit_lines( content, inner, available, scroll, focus_key != :findings ).map { |line| "#{ colorize( '│', border_role ) }#{ fit_line( line, inner ) }#{ colorize( '│', border_role ) }" }
        body << "#{ colorize( '│', border_role ) }#{ fit_line( '', inner ) }#{ colorize( '│', border_role ) }" while body.size < available
        [ colorize( top, border_role ), *body, colorize( bottom, border_role ) ]
      end

      def panel_scroll_offset( focus_key, content_size, visible_size )
        return 0 unless focus_key

        max_offset = [ content_size - visible_size, 0 ].max
        @panel_scroll_offsets[ focus_key ] = @panel_scroll_offsets[ focus_key ].to_i.clamp( 0, max_offset )
      end

      def ensure_panel_cursor_visible( panel_key, row, visible_size, content_size = nil, padding = 5 )
        return unless panel_key && row

        visible_size = visible_size.to_i
        offset = @panel_scroll_offsets[ panel_key ].to_i
        return if visible_size <= 0

        row = row.to_i
        top_padding = [ padding - 1, 0 ].max
        bottom_padding = [ padding, 0 ].max
        if visible_size <= top_padding + bottom_padding + 1
          top_padding = bottom_padding = [ ( visible_size - 1 ) / 2, 0 ].max
        end

        if row < offset + top_padding
          offset = row - top_padding
        elsif row > offset + visible_size - bottom_padding
          offset = row - visible_size + bottom_padding
        end

        max_offset = content_size ? [ content_size.to_i - visible_size, 0 ].max : nil
        offset = [ offset, 0 ].max
        offset = [ offset, max_offset ].min if max_offset
        @panel_scroll_offsets[ panel_key ] = offset
      end

      def fit_lines( lines, width, max_lines, offset = 0, mark_overflow = true )
        normalized = Array( lines ).map { |line| line.to_s }
        return [] if max_lines <= 0

        offset = offset.to_i.clamp( 0, [ normalized.size - max_lines, 0 ].max )
        if normalized.size > max_lines
          hidden_before = offset
          hidden_after = [ normalized.size - offset - max_lines, 0 ].max
          normalized = normalized.slice( offset, max_lines ) || []
          marker_text = hidden_before > 0 && hidden_after > 0 ? "  ⋯ #{ hidden_before } above/#{ hidden_after } below" :
                        hidden_before > 0 ? "  ⋯ #{ hidden_before } above" :
                        "  ⋯ #{ hidden_after } more"
          overflow_marker = colorize( marker_text, :muted )
          visible_width = [ width - display_width( overflow_marker ), 1 ].max
          normalized[ -1 ] = "#{ take_display( normalized[ -1 ], visible_width ).rstrip }#{ overflow_marker }" if mark_overflow
        end
        normalized.map { |line| fit_line( line, width ) }
      end

      def fit_line( line, width )
        line = clean_text( line )
        if display_width( line ) > width
          line = width > 1 ? take_display( line, width - 1 ) + '…' : take_display( line, width )
        end
        line + ( ' ' * [ width - display_width( line ), 0 ].max )
      end

      def take_display( line, width )
        output = +''
        consumed = 0
        line.to_s.scan( /#{ ANSI_RE }|./m ).each do |token|
          if token =~ ANSI_RE
            output << token
            next
          end
          token_width = char_width( token )
          break if consumed + token_width > width

          output << token
          consumed += token_width
        end
        output << RESET if @color_enabled && output.include?( "\033[" ) && ! output.end_with?( RESET )
        output
      end

      def clean_text( text )
        text.to_s.gsub( /\r/, '' )
                 .gsub( /\e\][^\a]*(?:\a|\e\\)/, '' )
                 .gsub( /\uFE0F/, '' )
                 .gsub( /OK\s*✅/, 'OK' )
                 .gsub( '✅', '[OK]' )
                 .gsub( '❌', '[ERR]' )
                 .gsub( /\n/, ' ' )
                 .gsub( /\t/, ' ' )
      end

      def display_width( line )
        strip_ansi( line ).each_char.sum { |char| char_width( char ) }
      end

      def strip_ansi( line )
        line.to_s.gsub( ANSI_RE, '' )
      end

      def char_width( char )
        codepoint = char.ord
        return 0 if codepoint < 32
        return 2 if ( codepoint >= 0x1100 && codepoint <= 0x115f ) ||
                    codepoint == 0x2329 ||
                    codepoint == 0x232a ||
                    ( codepoint >= 0x2e80 && codepoint <= 0xa4cf && codepoint != 0x303f ) ||
                    ( codepoint >= 0xac00 && codepoint <= 0xd7a3 ) ||
                    ( codepoint >= 0xf900 && codepoint <= 0xfaff ) ||
                    ( codepoint >= 0xfe10 && codepoint <= 0xfe19 ) ||
                    ( codepoint >= 0xfe30 && codepoint <= 0xfe6f ) ||
                    ( codepoint >= 0xff00 && codepoint <= 0xff60 ) ||
                    ( codepoint >= 0xffe0 && codepoint <= 0xffe6 )

        1
      end

      def console_size
        IO.console ? IO.console.winsize : [ 24, 100 ]
      rescue
        [ 24, 100 ]
      end

      def check_phase( kind )
        case kind
        when :hash then 'Hash checks'
        when :signature then 'Signatures'
        when :schema then 'Schema checks'
        else 'Checks'
        end
      end

      def activity_phase( text )
        case text
        when /Searching AssetMaps|Found .*Assetmap/i then 'Discovery'
        when /PKL|PackingList/i then 'PackingList'
        when /CPL|Composition/i then 'Composition'
        when /hash/i then 'Hash checks'
        when /Signature/i then 'Signatures'
        else nil
        end
      end

      def clear_current_hash_asset( subject )
        return unless @current_hash_asset && subject == @current_hash_asset
        return if subject.respond_to?( :hash_status ) && subject.hash_status == 'checking'

        @current_hash_asset = nil
        @progress = nil
        @hash_progress = nil
      end

      def hash_status_counts
        return Hash.new( 0 ) unless @run

        @run.assets.values.each_with_object( Hash.new( 0 ) ) do |asset, counts|
          counts[ asset.hash_status ] += 1 if asset.respond_to?( :hash_status ) && asset.hash_status
        end
      end

      def diagnostic_count( level )
        return @inspection_findings.fetch( level, [] ).size if @inspection_findings

        @diagnostics.count { |entry| entry[ :level ] == level }
      end

      def diagnostic_entries
        return @diagnostics unless @inspection_findings

        @inspection_findings.flat_map do |level, messages|
          messages.map { |message| { :level => level, :text => clean_text( message ).strip } }
        end
      end

      def current_related_composition_ids
        current_composition_ids
      end

      def prioritized_compositions
        prioritize_current_compositions( @run.compositions.values )
      end

      def prioritized_assets
        @run.assets.values.sort_by do |asset|
          current = asset == @current_hash_asset ? 0 : 1
          checking = asset.hash_status == 'checking' ? 0 : 1
          problem = ( asset.present == false || [ 'mismatch', 'empty' ].include?( asset.hash_status ) ) ? 0 : 1
          [ current, checking, problem, asset.assetmap_path.to_s, asset.id.to_s ]
        end
      end

      def prioritize_current_packages( packages )
        order_by_recency( packages, @recent_package_paths ) { |pkg| pkg.base_path }
      end

      def remember_current_panel_items
        current_am = current_assetmap
        remember_recent( @recent_package_paths, [ current_am && current_am.package && current_am.package.base_path ] )
        remember_recent( @recent_composition_ids, current_composition_ids )
      end

      def remember_recent( order, keys )
        keys = keys.compact.uniq
        return if keys.empty?

        order.replace( keys + order.reject { |key| keys.include?( key ) } )
      end

      def order_by_recency( items, order )
        ranks = order.each_with_index.to_h
        fallback = order.size
        items.each_with_index.sort_by do |item, original_index|
          key = yield( item )
          [ ranks.fetch( key, fallback + original_index ), original_index ]
        end.map( &:first )
      end

      def asset_context_lines( asset )
        lines = []
        package = asset.assetmap && asset.assetmap.package ? compact_path( asset.assetmap.package.base_path ) : compact_path( @root_path )
        lines << "DCP #{ package.empty? ? '.' : package }  AssetMap #{ asset.assetmap ? short_id( asset.assetmap.id ) : 'unknown' }  PKL #{ asset.packing_lists.map { |pkl| short_id( pkl.id ) }.join( ', ' ) }"
        if asset.reel_references.any?
          refs = asset.reel_references.map { |ref| "CPL #{ short_id( ref.reel.composition.id ) } R#{ ref.reel.number } #{ ref.kind }" }
          lines << refs.join( '  ' )
        else
          lines << 'No CPL reel reference known for this asset'
        end
        lines << compact_path( asset.assetmap_path || asset.packing_list_path || asset.absolute_path )
        lines
      end

      def status_token( node )
        checks = node.respond_to?( :checks ) ? node.checks : []
        return colorize( 'ERR', :error ) if checks.any? { |check| check.status == :error }
        if node.is_a?(Model::CompositionPlaylist)
          assets = node.reels.flat_map(&:assets).map(&:asset).compact
          return colorize('ERR', :error) if assets.any? { |asset| asset.present == false || asset.checks.any? { |check| check.status == :error } }
          return colorize('ERR', :error) if node.completeness_status == :incomplete
          return colorize('EXT', :warn) if node.completeness_status == :external
          return colorize('WRN', :warn) if node.completeness_status == :warning
          return colorize('···', :muted) if node.completeness_status == :pending
        end
        return colorize( 'OK ', :ok ) if checks.any? { |check| check.status == :ok }

        colorize( '···', :muted )
      end

      def signature_schema_label( node )
        [ node.schema_status ? "schema #{ node.schema_status }" : nil, node.signature_status ? "signature #{ node.signature_status }" : nil ].compact.join( '  ' )
      end

      def asset_state( asset )
        return 'missing' if asset.present == false
        return asset.hash_status if asset.hash_status

        'known'
      end

      def aligned_duration( frames, edit_rate )
        value = if frames && edit_rate && edit_rate.to_f > 0
          begin
            Timecode.new( frames.to_i, edit_rate.to_f ).to_s
          rescue
            "#{ frames }f"
          end
        elsif frames
          "#{ frames }f"
        else
          'pending'
        end
        value.rjust( 11 )
      end

      def type_label( type )
        return 'unknown' if type.nil? || type.to_s.empty?

        label = type.to_s.split( /[\/#]/ ).last
        label.empty? ? type.to_s : label
      end

      def size_label( bytes )
        return 'pending' unless bytes

        bytes.respond_to?( :to_k ) ? bytes.to_k : bytes.to_s
      end

      def compact_path( path )
        return '' unless path

        path = path.to_s
        root = @root_path || ( @run && @run.root_path )
        if root && path.start_with?( root.to_s )
          path.sub( /^#{ Regexp.escape( root.to_s ) }\/?/, '' )
        else
          path
        end
      end

      def short_id( id )
        id = id.to_s
        id.size > 13 ? id[ 0, 8 ] : id
      end

      def plural_suffix( count )
        count == 1 ? '' : 's'
      end

      def duration_label( seconds )
        total = seconds.to_i
        hours = total / 3600
        minutes = ( total % 3600 ) / 60
        secs = total % 60
        hours > 0 ? format( '%d:%02d:%02d', hours, minutes, secs ) : format( '%02d:%02d', minutes, secs )
      end
    end


    class TFSLogger < DLogger
      def initialize( prefix, options, dashboard, io = $stdout )
        super( prefix, options, io )
        @dashboard = dashboard
      end

      def dev( text ) activity_out( text, @dev ) end
      def info( text ) activity_out( text, @info ) end
      def debug( text ) activity_out( text, @debug ) end
      def cpl( text ) activity_out( text, @cpl ) end

      def errors( text )
        diagnostic_out( :error, text, @errors )
      end

      def hints( text )
        diagnostic_out( :hint, text, @hints )
      end

      def siginfo( text )
        diagnostic_out( :siginfo, text, @siginfo )
      end

      def cr( text )
        @dashboard.progress( text ) if @dashboard
      end

      def outbound( text )
        @dashboard.activity( text ) if @dashboard
        append_full_log( text )
      end

      def outbound_colored( text, color )
        outbound( text )
      end

      def to_console( text )
        outbound( text )
      end

      def carriage_return( text )
        cr( text )
      end

      private

      def activity_out( text, loggable )
        @dashboard.activity( text ) if @dashboard
        append_full_log( text ) if loggable
      end

      def diagnostic_out( level, text, loggable )
        @dashboard.diagnostic( level, text ) if @dashboard
        append_full_log( text ) if loggable
      end

      def append_full_log( text )
        @full_log << text if @full_log
      end
    end


  end
end
