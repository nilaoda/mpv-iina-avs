#!/usr/bin/env ruby
require 'fileutils'
require 'open3'
require 'shellwords'
include FileUtils::Verbose

def safe_system(*args)
  puts args.shelljoin
  system(*args) || abort('Failed command')
end

class DylibFile
  OTOOL_RX = /\t(.*) \(compatibility version (?:\d+\.)*\d+, current version (?:\d+\.)*\d+\)/
  attr_reader :path, :id, :deps

  def initialize(path)
    @path = path
    parse_otool_L_output!
  end

  def parse_otool_L_output!
    stdout, stderr, status = Open3.capture3('otool', '-L', path)
    abort(stderr) unless status.success?
    libs = stdout.split("\n")
    libs.shift
    @id = libs.shift[OTOOL_RX, 1]
    @deps = libs.map { |lib| lib[OTOOL_RX, 1] }.compact
  end

  def signing_path
    File.realpath(path)
  rescue StandardError
    path
  end

  def ensure_writeable
    saved_perms = nil
    unless File.writable_real?(path)
      saved_perms = File.stat(path).mode
      FileUtils.chmod 0o644, path
    end
    yield
  ensure
    FileUtils.chmod saved_perms, path if saved_perms
  end

  def change_id!
    ensure_writeable do
      safe_system 'install_name_tool', '-id', '@rpath/' + File.basename(id || path), path
    end
  end

  def change_install_name!(old_name, new_name)
    ensure_writeable do
      safe_system 'install_name_tool', '-change', old_name, new_name, path
    end
  end

  def sign!
    ensure_writeable do
      safe_system 'codesign', '--force', '--sign', '-', signing_path
    end
  end
end

abort('Usage: collect_dylibs.rb dest_dir prefix [prefix ...] entry_dylib') if ARGV.length < 3

def resolve_dependency(dep, prefixes, origin_dir)
  basename = File.basename(dep)

  case dep
  when /^@rpath\//
    prefixes.each do |prefix|
      candidate = Dir[File.join(prefix, '**', basename)].first
      return candidate if candidate
    end
    local = File.join(origin_dir, basename)
    return local if File.exist?(local)
  when /^@loader_path\//, /^@executable_path\//
    local = File.expand_path(dep.sub(/^@(?:loader_path|executable_path)/, origin_dir))
    return local if File.exist?(local)
  else
    prefixes.each do |prefix|
      return dep if dep.start_with?(prefix) && File.exist?(dep)
    end
    return dep if File.exist?(dep)
  end

  nil
end

dest_dir = File.expand_path(ARGV.shift)
prefixes = ARGV[0..-2].map { |prefix| File.expand_path(prefix) }
entry_dylib = File.realpath(ARGV[-1])
mkdir_p dest_dir

queue = [[entry_dylib, File.dirname(entry_dylib)]]
seen = {}

until queue.empty?
  file, origin_dir = queue.shift
  dylib = DylibFile.new(file)
  dest = File.join(dest_dir, File.basename(dylib.id || file))
  copy_entry file, dest, preserve: true unless File.exist?(dest)
  next if seen[dest]
  seen[dest] = true

  dylib = DylibFile.new(dest)
  dylib.change_id!
  dylib.deps.each do |dep|
    next if dep.start_with?('/usr/lib/', '/System/Library/')
    basename = File.basename(dep)
    dylib.change_install_name!(dep, "@rpath/#{basename}")

    src = resolve_dependency(dep, prefixes, origin_dir)
    next unless src && File.exist?(src)

    target = File.join(dest_dir, basename)
    queue << [File.realpath(src), File.dirname(src)] unless File.exist?(target)
  end

  dylib.sign!
end
