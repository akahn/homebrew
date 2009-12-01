#  Copyright 2009 Max Howell and other contributors.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
#  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
#  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
#  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
#  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
#  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
#  NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
#  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
FORMULA_META_FILES = %w[README ChangeLog COPYING LICENSE COPYRIGHT AUTHORS]
PLEASE_REPORT_BUG = "#{Tty.white}Please report this bug at #{Tty.em}http://github.com/mxcl/homebrew/issues#{Tty.reset}"


def __make url, name
  require 'formula'
  require 'erb'

  path = Formula.path(name)
  raise "#{path} already exists" if path.exist?
  
  # Check if a formula aliased to this name exists.
  already_aka = Formulary.find_alias name
  if already_aka != nil
    opoo "Formula #{already_aka} is aliased to #{name}."
    puts "Please check if you are creating a duplicate."
  end

  if ARGV.include? '--cmake'
    mode = :cmake
  elsif ARGV.include? '--autotools'
    mode = :autotools
  else
    mode = nil
  end

  formula = <<-EOS
require 'formula'

class #{Formula.class_s name} < Formula
  url '#{url}'
  homepage ''
  md5 ''

<% if mode == :cmake %>
  depends_on 'cmake'
<% elsif mode == nil %>
  # depends_on 'cmake'
<% end %>

  def install
  <% if mode == :cmake %>
    system "cmake . \#{std_cmake_parameters}"
  <% elsif mode == :autotools %>
    system "./configure", "--prefix=\#{prefix}", "--disable-debug", "--disable-dependency-tracking"
  <% else %>
    system "./configure", "--prefix=\#{prefix}", "--disable-debug", "--disable-dependency-tracking"
    # system "cmake . \#{std_cmake_parameters}"
  <% end %>
    system "make install"
  end
end
  EOS

  template = ERB.new(formula, nil, '>')

  File.open(path, 'w') do |f|
    f.write(template.result(binding))
  end

  return path
end

def make url
  path = Pathname.new url

  /(.*?)[-_.]?#{path.version}/.match path.basename

  unless $1.to_s.empty?
    name = $1
  else
    print "Formula name [#{path.stem}]: "
    gots = $stdin.gets.chomp
    if gots.empty?
      name = path.stem
    else
      name = gots
    end
  end

  force_text = "If you really want to make this formula use --force."

  case name.downcase
  when /libxml/, /libxlst/, /freetype/, /libpng/, /wxwidgets/
    raise <<-EOS
#{name} is blacklisted for creation
Apple distributes this library with OS X, you can find it in /usr/X11/lib.
However not all build scripts look here, so you may need to call ENV.x11 or
ENV.libxml2 in your formula's install function.

#{force_text}
    EOS
  when /rubygem/
    raise "Sorry RubyGems comes with OS X so we don't package it.\n\n#{force_text}"
  end unless ARGV.force?

  __make url, name
end


def info name
  require 'formula'

  user=''
  user=`git config --global github.user`.chomp if system "/usr/bin/which -s git"
  user='mxcl' if user.empty?
  # FIXME it would be nice if we didn't assume the default branch is master
  history="http://github.com/#{user}/homebrew/commits/master/Library/Formula/#{Formula.path(name).basename}"

  exec 'open', history if ARGV.flag? '--github'

  f=Formula.factory name
  puts "#{f.name} #{f.version}"
  puts f.homepage

  if not f.deps.empty?
    puts "Depends on: #{f.deps.join(', ')}"
  end

  if f.prefix.parent.directory?
    kids=f.prefix.parent.children
    kids.each do |keg|
      print "#{keg} (#{keg.abv})"
      print " *" if f.prefix == keg and kids.length > 1
      puts
    end
  else
    puts "Not installed"
  end

  if f.caveats
    puts
    puts f.caveats
    puts
  end

  puts history

rescue FormulaUnavailableError
  # check for DIY installation
  d=HOMEBREW_PREFIX+name
  if d.directory?
    ohai "DIY Installation"
    d.children.each {|keg| puts "#{keg} (#{keg.abv})"}
  else
    raise "No such formula or keg"
  end
end


def clean f
  Cleaner.new f
 
  # Hunt for empty folders and nuke them unless they are
  # protected by f.skip_clean?
  # We want post-order traversal, so put the dirs in a stack
  # and then pop them off later.
  paths = []
  f.prefix.find do |path|
    paths << path if path.directory?
  end

  until paths.empty? do
    d = paths.pop
    if d.children.empty? and not f.skip_clean? d
      puts "rmdir: #{d} (empty)" if ARGV.verbose?
      d.rmdir
    end
  end
end


def expand_deps ff
  deps = []
  ff.deps.collect do |f|
    deps += expand_deps(Formula.factory(f))
  end
  deps << ff
end


def prune
  $n=0
  $d=0

  dirs=Array.new
  paths=%w[bin sbin etc lib include share].collect {|d| HOMEBREW_PREFIX+d}

  paths.each do |path|
    path.find do |path|
      path.extend ObserverPathnameExtension
      if path.symlink?
        path.unlink unless path.resolved_path_exists?
      elsif path.directory?
        dirs<<path
      end
    end
  end

  dirs.sort.reverse_each {|d| d.rmdir_if_possible}

  if $n == 0 and $d == 0
    puts "Nothing pruned" if ARGV.verbose?
  else
    # always showing symlinks text is deliberate
    print "Pruned #{$n} symbolic links "
    print "and #{$d} directories " if $d > 0
    puts  "from #{HOMEBREW_PREFIX}"
  end
end


def diy
  path=Pathname.getwd

  if ARGV.include? '--set-version'
    version=ARGV.next
  else
    version=path.version
    raise "Couldn't determine version, try --set-version" if version.nil? or version.empty?
  end
  
  if ARGV.include? '--set-name'
    name=ARGV.next
  else
    path.basename.to_s =~ /(.*?)-?#{version}/
    if $1.nil? or $1.empty?
      name=path.basename
    else
      name=$1
    end
  end

  prefix=HOMEBREW_CELLAR+name+version

  if File.file? 'CMakeLists.txt'
    "-DCMAKE_INSTALL_PREFIX=#{prefix}"
  elsif File.file? 'Makefile.am'
    "--prefix=#{prefix}"
  end
end

def macports_or_fink_installed?
  # See these issues for some history:
  # http://github.com/mxcl/homebrew/issues/#issue/13
  # http://github.com/mxcl/homebrew/issues/#issue/41
  # http://github.com/mxcl/homebrew/issues/#issue/48

  %w[port fink].each do |ponk|
    path = `/usr/bin/which -s #{ponk}`
    return ponk unless path.empty?
  end

  # we do the above check because macports can be relocated and fink may be
  # able to be relocated in the future. This following check is because if
  # fink and macports are not in the PATH but are still installed it can
  # *still* break the build -- because some build scripts hardcode these paths:
  %w[/sw/bin/fink /opt/local/bin/port].each do |ponk|
    return ponk if File.exist? ponk
  end

  # finally, sometimes people make their MacPorts or Fink read-only so they
  # can quickly test Homebrew out, but still in theory obey the README's 
  # advise to rename the root directory. This doesn't work, many build scripts
  # error out when they try to read from these now unreadable directories.
  %w[/sw /opt/local].each do |path|
    path = Pathname.new(path)
    return path if path.exist? and not path.readable?
  end
  
  false
end

def versions_of(keg_name)
  `ls #{HOMEBREW_CELLAR}/#{keg_name}`.collect { |version| version.strip }.reverse
end


########################################################## class PrettyListing
class PrettyListing
  def initialize path
    Pathname.new(path).children.sort{ |a,b| a.to_s.downcase <=> b.to_s.downcase }.each do |pn|
      case pn.basename.to_s
      when 'bin', 'sbin'
        pn.find { |pnn| puts pnn unless pnn.directory? }
      when 'lib'
        print_dir pn do |pnn|
          # dylibs have multiple symlinks and we don't care about them
          (pnn.extname == '.dylib' or pnn.extname == '.pc') and not pnn.symlink?
        end
      else
        if pn.directory?
          print_dir pn
        elsif not FORMULA_META_FILES.include? pn.basename.to_s
          puts pn
        end
      end
    end
  end

private
  def print_dir root
    dirs = []
    remaining_root_files = []
    other = ''

    root.children.sort.each do |pn|
      if pn.directory?
        dirs << pn
      elsif block_given? and yield pn
        puts pn
        other = 'other '
      else
        remaining_root_files << pn 
      end
    end

    dirs.each do |d|
      files = []
      d.find { |pn| files << pn unless pn.directory? }
      print_remaining_files files, d
    end

    print_remaining_files remaining_root_files, root, other
  end

  def print_remaining_files files, root, other = ''
    case files.length
    when 0
      # noop
    when 1
      puts *files
    else
      puts "#{root}/ (#{files.length} #{other}files)"
    end
  end
end


################################################################ class Cleaner
class Cleaner
  def initialize f
    @f=f
    
    # correct common issues
    share=f.prefix+'share'
    (f.prefix+'man').mv share rescue nil
    
    [f.bin, f.sbin, f.lib].each {|d| clean_dir d}
    
    # you can read all of this stuff online nowadays, save the space
    # info pages are pants, everyone agrees apart from Richard Stallman
    # feel free to ask for build options though! http://bit.ly/Homebrew
    (f.prefix+'share'+'doc').rmtree rescue nil
    (f.prefix+'share'+'info').rmtree rescue nil
    (f.prefix+'doc').rmtree rescue nil
    (f.prefix+'docs').rmtree rescue nil
    (f.prefix+'info').rmtree rescue nil
  end

private
  def strip path, args=''
    return if @f.skip_clean? path
    puts "strip #{path}" if ARGV.verbose?
    path.chmod 0644 # so we can strip
    unless path.stat.nlink > 1
      `strip #{args} #{path}`
    else
      # strip unlinks the file and recreates it, thus breaking hard links!
      # is this expected behaviour? patch does it too… still, this fixes it
      tmp=`mktemp -t #{path.basename}`.strip
      `strip #{args} -o #{tmp} #{path}`
      `cat #{tmp} > #{path}`
      File.unlink tmp
    end
  end

  def clean_file path
    perms=0444
    case `file -h '#{path}'`
    when /Mach-O dynamically linked shared library/
      strip path, '-SxX'
    when /Mach-O [^ ]* ?executable/
      strip path
      perms=0555
    when /script text executable/
      perms=0555
    end
    path.chmod perms
  end

  def clean_dir d
    d.find do |path|
      if path.directory?
        Find.prune if @f.skip_clean? path
      elsif not path.file?
        next
      elsif path.extname == '.la' and not @f.skip_clean? path
        # *.la files are stupid
        path.unlink
      elsif not path.symlink?
        clean_file path
      end
    end
  end
end

def gcc_build
  `/usr/bin/gcc-4.2 -v 2>&1` =~ /build (\d{4,})/
  $1.to_i
end

def llvm_build
  if MACOS_VERSION >= 10.6
    `/Developer/usr/bin/llvm-gcc-4.2 -v 2>&1` =~ /LLVM build (\d{4,})/  
    $1.to_i
  end
end
