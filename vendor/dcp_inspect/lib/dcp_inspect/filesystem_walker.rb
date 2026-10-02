# frozen_string_literal: true

require "open3"
require "pathname"

module DcpInspect
  class FilesystemWalker
    class TraversalError < StandardError; end

    ASSETMAP_FILENAMES = ["ASSETMAP", "ASSETMAP.xml"].freeze
    ASSETMAP_PATTERN = "^(?:ASSETMAP|ASSETMAP\\.xml)$"
    FILESYSTEM_ERRORS = [
      Errno::EACCES,
      Errno::EINVAL,
      Errno::ELOOP,
      Errno::ENAMETOOLONG,
      Errno::ENOENT,
      Errno::ENOTDIR
    ].freeze

    attr_reader :backend, :fd_command, :warnings

    def initialize(backend: :auto, fd_command: nil, environment: ENV)
      @fd_command = fd_command || self.class.find_fd(environment: environment)
      @backend = resolve_backend(backend)
      @warnings = []
    end

    def self.find_fd(environment: ENV)
      path = environment.fetch("PATH", "")
      %w[fdfind fd].each do |name|
        path.split(File::PATH_SEPARATOR).each do |directory|
          candidate = File.expand_path(name, directory.empty? ? "." : directory)
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
      end
      nil
    end

    def assetmap_candidates(root)
      logical_root = validated_root(root)
      paths = if backend == :fd
                fd_files(logical_root, pattern: ASSETMAP_PATTERN, case_sensitive: true)
              else
                ruby_files(logical_root)
              end

      paths.filter_map do |path|
        next unless ASSETMAP_FILENAMES.include?(File.basename(path))

        Pathname.new(path).relative_path_from(Pathname.new(logical_root)).to_s
      end.then { |candidates| sort_paths(candidates) }
    end

    def files(root)
      logical_root = validated_root(root)
      paths = backend == :fd ? fd_files(logical_root) : ruby_files(logical_root)
      sort_paths(paths)
    end

    private

    def resolve_backend(requested)
      case requested.to_sym
      when :auto
        fd_command ? :fd : :ruby
      when :fd
        raise TraversalError, "fd/fdfind executable not found" unless fd_command

        :fd
      when :ruby
        :ruby
      else
        raise ArgumentError, "Unknown filesystem walker backend #{requested.inspect}"
      end
    end

    def validated_root(root)
      root_path = root.respond_to?(:to_path) ? root.to_path : root.to_s
      logical_root = File.expand_path(root_path)
      raise TraversalError, "Discovery root does not exist: #{logical_root}" unless File.exist?(logical_root)
      raise TraversalError, "Discovery root is not a directory: #{logical_root}" unless File.directory?(logical_root)

      @warnings.clear
      logical_root
    end

    def fd_files(logical_root, pattern: "", case_sensitive: false)
      command = [fd_command, "--type", "file", "--hidden", "--no-ignore", "--print0", "--show-errors"]
      command << "--case-sensitive" if case_sensitive
      command.concat([pattern, logical_root])

      stdout, stderr, status = Open3.capture3(*command)
      @warnings.concat(stderr.lines.map(&:strip).reject(&:empty?))
      unless status.success?
        detail = @warnings.empty? ? "exit #{status.exitstatus}" : @warnings.join("; ")
        raise TraversalError, "fd traversal failed for #{logical_root}: #{detail}"
      end

      stdout.split("\0", -1).reject(&:empty?).map do |path|
        path.start_with?(File::SEPARATOR) ? path : File.expand_path(path, logical_root)
      end
    rescue Errno::ENOENT => error
      raise TraversalError, "fd traversal failed: #{error.message}"
    end

    def ruby_files(logical_root)
      physical_root = File.realpath(logical_root)
      stack = [physical_root]
      files = []

      until stack.empty?
        begin
          path = stack.pop
          stat = File.lstat(path)
          if stat.directory?
            Dir.children(path).sort.reverse_each { |child| stack << File.join(path, child) }
          elsif stat.file?
            relative = path.delete_prefix(physical_root).delete_prefix(File::SEPARATOR)
            files << (relative.empty? ? logical_root : File.join(logical_root, relative))
          end
        rescue *FILESYSTEM_ERRORS => error
          @warnings << "#{path}: #{error.message}"
        end
      end

      files
    end

    def sort_paths(paths)
      paths.sort_by { |path| [path.b.downcase, path.b] }
    end
  end
end
