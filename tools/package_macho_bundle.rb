#!/usr/bin/env ruby
require 'fileutils'
require 'open3'
require 'shellwords'
include FileUtils::Verbose

def safe_system(*args)
  puts args.shelljoin
  system(*args) || abort('Failed command')
end

class MachOFile
  OTOOL_RX = /\t(.*) \(compatibility version (?:\d+\.)*\d+, current version (?:\d+\.)*\d+\)/
  attr_reader :path, :deps

  def initialize(path)
    @path = path
    parse_otool_L_output!
  end

  def dylib?
    File.basename(path).include?('.dylib')
  end

  def signing_path
    File.realpath(path)
  rescue StandardError
    path
  end

  def parse_otool_L_output!
    stdout, stderr, status = Open3.capture3('otool', '-L', path)
    abort(stderr) unless status.success?
    libs = stdout.split("\n")
    libs.shift
    @deps = libs.map { |lib| lib[OTOOL_RX, 1] }.compact
  end

  def ensure_writeable
    saved_perms = nil
    unless File.writable_real?(path)
      saved_perms = File.stat(path).mode
      FileUtils.chmod 0o755, path
    end
    yield
  ensure
    FileUtils.chmod saved_perms, path if saved_perms
  end

  def change_id!(new_id)
    return unless dylib?

    ensure_writeable do
      safe_system 'install_name_tool', '-id', new_id, path
    end
  end

  def change_install_name!(old_name, new_name)
    return if old_name == new_name

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

abort('Usage: package_macho_bundle.rb dest_root prefix [prefix ...] -- entry [entry ...]') unless ARGV.include?('--')
sep_index = ARGV.index('--')
dest_root = File.expand_path(ARGV.shift)
sep_index -= 1
prefixes = ARGV.shift(sep_index).map { |prefix| File.expand_path(prefix) }
ARGV.shift
entries = ARGV.map { |entry| File.realpath(entry) }
abort('At least one prefix is required') if prefixes.empty?
abort('At least one entry binary is required') if entries.empty?

bin_dir = File.join(dest_root, 'bin')
lib_dir = File.join(dest_root, 'lib')
mkdir_p bin_dir
mkdir_p lib_dir

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

queue = entries.map { |entry| [entry, File.dirname(entry), :bin, File.basename(entry)] }
seen = {}

until queue.empty?
  src, origin_dir, kind, basename = queue.shift
  dest = kind == :lib ? File.join(lib_dir, basename) : File.join(bin_dir, basename)
  copy_entry src, dest, preserve: true unless File.exist?(dest)
  if kind == :lib
    real_basename = File.basename(src)
    if real_basename != basename
      real_dest = File.join(lib_dir, real_basename)
      copy_entry src, real_dest, preserve: true unless File.exist?(real_dest)
      if !File.exist?(dest)
        File.symlink(real_basename, dest)
      elsif File.file?(dest) && !File.symlink?(dest)
        FileUtils.rm_f(dest)
        File.symlink(real_basename, dest)
      end
    end
  end
  next if seen[dest]
  seen[dest] = true

  macho = MachOFile.new(dest)
  macho.change_id!("@rpath/#{basename}") if kind == :lib

  macho.deps.each do |dep|
    next if dep.start_with?('/usr/lib/', '/System/Library/')

    resolved = resolve_dependency(dep, prefixes, origin_dir)
    next unless resolved && File.exist?(resolved)

    dep_basename = File.basename(dep)
    dep_kind = dep_basename.include?('.dylib') ? :lib : :bin
    next unless dep_kind == :lib

    new_name = if kind == :bin
                 "@executable_path/../lib/#{dep_basename}"
               else
                 "@loader_path/#{dep_basename}"
               end
    macho.change_install_name!(dep, new_name)

    target = File.join(lib_dir, dep_basename)
    queue << [File.realpath(resolved), File.dirname(resolved), :lib, dep_basename] unless File.exist?(target)
  end

  macho.sign!
end
