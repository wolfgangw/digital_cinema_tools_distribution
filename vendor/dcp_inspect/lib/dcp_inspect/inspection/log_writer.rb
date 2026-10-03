# frozen_string_literal: true
require 'digest'

module DcpInspect
  module Inspection
    module LogWriter
      module_function
      def compact_path(path)
        stem = File.basename(path).encode('UTF-8', invalid: :replace, undef: :replace, replace: '_')
          .gsub(/[^\p{Alnum}._-]/, '_').byteslice(0, 80).scrub('')
        File.join(File.dirname(path), "#{stem}-#{Digest::SHA256.hexdigest(File.expand_path(path))[0, 16]}.log")
      end

      def write(path, content, append: false, overwrite: false)
        store(path, content, append: append, overwrite: overwrite)
        { path: path, recovered: false }
      rescue Errno::ENAMETOOLONG
        shorter = compact_path(path)
        # A shorter basename cannot repair an overlong/unusable directory path.
        # Never redirect a report silently to another directory.
        100.times do |index|
          candidate = index.zero? ? shorter : shorter.sub(/\.log\z/, "-#{index}.log")
          begin
            store(candidate, content, append: append, overwrite: false)
            return { path: candidate, recovered: true }
          rescue Errno::EEXIST
            raise if append
          end
        end
        raise IOError, "No unused shortened logfile name available in #{File.dirname(path)}"
      end

      def store(path, content, append:, overwrite:)
        flags = File::WRONLY | File::CREAT | (append ? File::APPEND : overwrite ? File::TRUNC : File::EXCL)
        File.open(path, flags) { |file| file.write(content) }
      end
    end
  end
end
