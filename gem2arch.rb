#!/usr/bin/ruby

require 'digest/sha1'
require 'erubis'
require 'json'
require 'optparse'
require 'ostruct'
require 'rubygems/name_tuple'
require 'rubygems/package'
require 'rubygems/remote_fetcher'


#TODO: generate correct native depepdencies (spec.requirements)
#TODO: check spec.required_ruby_version matches current version
#TODO: check require_paths and remove ext for native gems
#TODO: in case if the package is marked as out of date - do not report about it to user
#TODO: install man pages
#TODO: check that local version matches remote
#TODO: do not install gem documentation? --no-documentation

# A number of gems is provided by standard 'ruby' package.
# There are several packages provided but only a few of them conflict with *.gem
CONFLICT_GEMS = %w(rake rdoc)

PACKAGE_VERSION_REGEX = /^\d+(\.\d+)*$/ # version should consist only from numbers and dots

PKGBUILD = %{# Generated by gem2arch (https://github.com/anatol/gem2arch)
<% for m in maintainers %>
# Maintainer: <%= m %>
<% end %>
<% for c in contributors %>
# Contributor: <%= c %>
<% end %>

_gemname=<%= gem_name %>
pkgname=ruby-$_gemname<%= version_suffix %>
pkgver=<%= gem_ver %>
pkgrel=1
pkgdesc='<%= description %>'
arch=(<%= arch %>)
url='<%= website %>'
license=(<%= license %>)
depends=(<%= depends %>)
options=(!emptydirs)
source=(https://rubygems.org/downloads/$_gemname-$pkgver.gem)
noextract=($_gemname-$pkgver.gem)
sha1sums=('<%= sha1sum %>')

package() {
  local _gemdir="$(ruby -e'puts Gem.default_dir')"
  gem install --ignore-dependencies --no-user-install -i "$pkgdir/$_gemdir" -n "$pkgdir/usr/bin" $_gemname-$pkgver.gem
  rm "$pkgdir/$_gemdir/cache/$_gemname-$pkgver.gem"
<% for license_file in license_files %>
  install -D -m644 "$pkgdir/$_gemdir/gems/$_gemname-$pkgver/<%= license_file %>" "$pkgdir/usr/share/licenses/$pkgname/<%= license_file %>"
<% end %>
<% if remove_binaries %>
  # non-HEAD version should not install any files in /usr/bin
  rm -r "$pkgdir/usr/bin/"
<% end %>
}
}

def read_pkgbuild_tags(content, tag)
  content.scan(/^\s*\#\s*#{tag}\s*:(.*)$/).flatten.map{|s| s.strip}.reject{|s| s.empty?}
end

class PkgBuild
  attr_reader :slot, :dependencies
  attr_accessor :name, :version, :release, :maintainers, :contributors, :license

  def initialize(filename)
    @filename = filename
    unless File.exist?(filename)
      @maintainers = []
      @contributors = []
      return
    end

    @content = IO.read(@filename)

    @name = @content.match('_gemname=(\S+)')[1]
    @version = @content.match('pkgver=([\d\.]+)')[1]
    @release = @content.match('pkgrel=(\d+)')[1].to_i
    # dependencies contains only native (non-gem) packages
    @dependencies = @content.match('depends=\((.*)\)')[1].split.reject{|d| d.start_with?('ruby-')}
    @slot = @content.match('pkgname=ruby-\$_gemname-([\d\.]+)')[1] rescue nil

    @maintainers = read_pkgbuild_tags(@content, 'Maintainer')
    @contributors = read_pkgbuild_tags(@content, 'Contributor')

    # Many ruby gems do not have license field initialized. Read one from exising PKGBUILD so we can use later if upstream did not provide license.
    @license = @content.match('license\s*=(.*)')[1].scan(/[a-zA-Z\d\-\.]*/).flatten.reject{|s| s.empty?}[0]
  end

  def to_s
    str = 'ruby-' + @name
    str = str + '-' + @slot if @slot
    return str
  end

  def bump
    modified = false
    version_bump = false

    # we can change wither dependencies or version
    dep = @dependencies.join(' ')

    m = @content.match('depends=\((.*)\)')[1]
    if m != dep
      modified = true
      @release += 1
      @content.gsub!(/depends=\((.*)\)/, "depends=\(#{dep}\)")
    end

    m = @content.match('pkgver=([\d\.]+)')[1]
    if m != @version
      modified = true
      version_bump = true
      @release = 1
      @content.gsub!(/pkgver=([\d\.]+)/, "pkgver=#{@version}")
    end

    @content.gsub!(/pkgrel=\d+/, "pkgrel=#{@release}")

    IO.write(@filename, @content)

    if version_bump
      `cd #{File.dirname(@filename)} && updpkgsums 2> /dev/null`
      abort("Cannot run updpkgsums for modifications in #{@filename}") unless $?.success?
    end

    return modified
  end

  def generate

  end

  def makepackage
    dir = File.dirname(@filename)
    `cd #{dir} && makepkg --nodeps -f -i`
    return $?.success?
  end

  def upload
    dir = File.dirname(@filename)
    `cd #{dir} && rm -f *.src.tar.gz && makepkg -S -f && burp #{to_s()}-#{@version}-#{@release}.src.tar.gz`
    return $?.success?
  end
end

def pkg_to_spec(pkg)
  req = nil
  if pkg.slot
    req = Gem::Requirement.new('~>' + pkg.slot + '.0')
  end

  dep = Gem::Dependency.new(pkg.name, req)
  found,_ = Gem::SpecFetcher.fetcher.spec_for_dependency(dep)
  if found.empty?
    puts "Could not find releases for gem #{pkg.name}"
    return nil
  end

  spec,_ = found.sort_by{|(s,_)| s.version }.last
  return spec
end

# converts ruby dependency into arch name
# the problem is when dependency uses '=' or '~>' restriction that does not match the last version of the package
# we need to find the least restricted versioned arch package name
def dependency_suffix(dep)
  dep.to_s # this is a workaround for "undefined method `none?'". I can't explain it (ruby GC issue?).
  return nil if dep.latest_version?

  all_versions = @index[dep.name]

  # now we need to find the best (the last) version that matches provided dependency
  required_ind = all_versions.rindex{|v| dep.requirement.satisfied_by?(v)}
  required_version = all_versions[required_ind]
  next_version = all_versions[required_ind+1]

  abort("Cannot resolve package dependency: #{dep}") unless required_version
  # if required version is already the last version then we don't need a versioned dependency
  return nil unless next_version

  suffix = ''
  v1 = required_version.to_s.split('.')
  v2 = next_version.to_s.split('.')
  v1.zip(v2).each do |p1,p2|
    abort("Cannot generate arch name for dependency #{dep}") unless p1
    if p1 == p2
      suffix = suffix + p1 + '.'
    else
      suffix = suffix + p1
      break
    end
  end

  return suffix
end

def dependency_to_arch(dep)
  suffix = dependency_suffix(dep)
  arch_name = 'ruby-' + dep.name
  arch_name += '-' + suffix if suffix
  return arch_name
end


# returns name => array of Gem::Versions
def load_gem_index
  url = Gem.default_sources[0]
  source = Gem::Source.new(url)

  index = {}
  name = nil
  array = nil
  source.load_specs(:released).each do |e|
    next unless e.match_platform?
    if e.name != name
      name = e.name
      array = []
      index[name] = array
    end
    array << e.version
  end

  return index
end

@version_cache = {} # String->OpenStruct
def find_arch_version(package, gem_name, suffix)
  return @version_cache[package] if @version_cache.include?(package)

  pkg = nil
  # First check extra/community
  pacinfo = `pacman -Si #{package} 2>/dev/null`
  if $?.success?
    pkg = OpenStruct.new
    pkg.aur = false
    pkg.version = /Version\s*:(.*)-\d+/.match(pacinfo)[1].strip
    repo = /Repository\s*:(.*)/.match(pacinfo)[1].strip
    arch = /Architecture\s*:(.*)/.match(pacinfo)[1].strip
    pkg.url = "https://www.archlinux.org/packages/#{repo}/#{arch}/#{package}/"
  end

  unless pkg
    aur_request = "https://aur.archlinux.org/rpc.php?type=info&arg=#{package}"
    resp = Net::HTTP.get_response(URI.parse(aur_request))
    result = JSON.parse(resp.body)
    if result['resultcount'] > 0
      pkg = OpenStruct.new
      pkg.aur = true
      pkg.url = "https://aur.archlinux.org/packages/#{package}/"
      pkg.version = /(.*)-\d+/.match(result['results']['Version'])[1]
    end
  end

  @version_cache[package] = pkg

  if pkg
    if suffix
      req = Gem::Requirement.new('~>' + suffix + '.0')
    else
      req = Gem::Requirement.default
    end
    latest = @index[gem_name].select{|v| req.satisfied_by?(v)}.last
    if latest.to_s != pkg.version
      puts "Package #{package} is out-of-date (repo=#{pkg.version} gem=#{latest.version.to_s}). Please visit #{pkg.url} and mark it so."
    end
  else
    puts "Package #{package} does not exist. Please create one."
  end

  return pkg
end

def parse_args(args)
  options = OpenStruct.new
  options.use_git = true
  options.install = true
  options.upload_aur = false
  options.packages = []

  opt_parser = OptionParser.new do |opts|
    opts.banner = "Usage: gem2arch [options] [gem_name[~version]]...\n
  If package_suffix present then arch package will be called ruby-$gem_name-$version and gem version will be ~>$version.0"

    opts.on('-g', '--[no-]git', 'Commit PKGBUILD changes to git repository') do |g|
      options.use_git = g
    end
    opts.on('-u', '--[no-]aur', 'Upload created packages to AUR') do |u|
      options.upload_aur = u
    end
    opts.on('-i', '--[no-]install', 'Install generated arch packages') do |i|
      options.install = i
    end
  end

  opt_parser.parse!(args)
  unless args.empty?
    # packages for creation were specified
    options.packages = args.map{ |a|
      parts = a.split('~')
      abort("Invalid package name #{a}") if parts.size < 1 or parts.size > 2
      abort("Invalid package number #{a}") if parts[1] and parts[1] !~ PACKAGE_VERSION_REGEX
      parts
    }
  end

  return options
end

def bump_package(file, options)
  correct_deps = true

  pkg = PkgBuild.new(file)
  spec = pkg_to_spec(pkg)
  return unless spec

  pkg.version = spec.version.to_s
  new_deps = spec.runtime_dependencies.reject{|d| CONFLICT_GEMS.include?(d.name) }
  for d in new_deps
    arch_name = dependency_to_arch(d)
    suffix = dependency_suffix(d)
    pkg.dependencies << arch_name

    arch_pkg = find_arch_version(arch_name, d.name, suffix)
    unless arch_pkg
      # no such package
      correct_deps = false
      puts "#{pkg}=>#{arch_name} does not satisfy gem dependency restrictions"
      return
    end

    # make sure we match spec requirement
    unless d.requirement.satisfied_by?(Gem::Version.new(arch_pkg.version))
      # Most likely it means arch_name should be updated
      puts "#{pkg}=>#{arch_name} does not satisfy gem dependency restrictions"
    end
  end

  return unless correct_deps

  modified = pkg.bump
  if modified
    `git add #{file} && git commit -m '#{pkg}: bump'` if options.use_git
    pkg.makepackage if options.install  # TODO: check return value?

    if options.upload_aur
      uploaded = pkg.upload
      puts "Cannot upload changes for package #{pkg}" unless uploaded
    end
  end
end

def bump_packages(options)
  Dir['ruby-*/PKGBUILD'].each{|f| bump_package(f, options)}
end

def current_username
  # Many users have git configured. Let's use it to find current user/email.
  name = `git config --get user.name`.strip
  return nil unless $?.success?

  email = `git config --get user.email`.strip
  return nil unless $?.success?

  return nil if name.empty? or email.empty?
  return "#{name} <#{email}>"
end

def find_license_files(spec)
  # find files called COPYING or LICENSE in the root directory
  license_files = spec.files.select do |f|
    next false if f.index('/')
    next true if f.downcase.index('license')
    next true if f.downcase.index('copying')
    next true if f.downcase.index('copyright')
    false
  end

  return license_files
end

def download(gem_name, suffix)
  req = suffix ? Gem::Requirement.new('~>' + suffix + '.0') : nil
  dependency = Gem::Dependency.new(gem_name, req)
  found, _ = Gem::SpecFetcher.fetcher.spec_for_dependency(dependency)

  if found.empty?
    $stderr.puts "Could not find #{gem_name} in any repository"
    exit 1
  end

  spec, source = found.sort_by{ |(s,_)| s.version }.last
  path = Gem::RemoteFetcher.fetcher.download(spec, source.uri.to_s)

  return path
end

def shell_escape_string(str)
  str.gsub("'", "'\\\\''")
end

def check_gem_dependencies(dependencies)
  more = []
  for d in dependencies do
    arch_name = dependency_to_arch(d)
    suffix = dependency_suffix(d)
    pkg = find_arch_version(arch_name, d.name, suffix)
    unless pkg
      $stderr.puts "Cannot find package for dependency: #{arch_name}. Generate it as well."
      more << [d.name, suffix]
      next
    end

    # Fetch version information for the gem
    dep = Gem::Dependency.new(d.name, nil)
    dep_found, _ = Gem::SpecFetcher.fetcher.spec_for_dependency(dep)
    dep_spec, _ = dep_found.sort_by{ |(s,_)| s.version }.last
    unless d.requirement.satisfied_by?(Gem::Version.new(pkg.version))
      $stderr.puts "Package #{arch_name} version does not satisfy gem dependency"
    end
  end

  return more
end

def gen_pkgbuild(gem_path, existing_pkgbuild, suffix)
  gem = Gem::Package.new(gem_path)
  spec = gem.spec

  existing_pkgbuild.name = spec.name
  existing_pkgbuild.version = spec.version
  existing_pkgbuild.release = 1

  arch = spec.extensions.empty? ? 'any' : 'i686 x86_64'
  sha1sum = Digest::SHA1.file(gem_path).hexdigest

  gem_dependencies = spec.runtime_dependencies.reject{|d| CONFLICT_GEMS.include?(d.name) }
  more = check_gem_dependencies(gem_dependencies)
  depends = %w(ruby)
  depends += gem_dependencies.map{|d| dependency_to_arch(d)}

  spec_licenses = spec.licenses
  if spec_licenses.empty? and existing_pkgbuild.license
    spec_licenses = [existing_pkgbuild.license]
  end
  licenses = spec_licenses.map{|l| l.index(' ') ? "'#{l}'" : l}

  maintainers = existing_pkgbuild.maintainers
  contributors = existing_pkgbuild.contributors
  if maintainers.empty?
    username = current_username()
    maintainers = username ? [username] : ['']
  end

  # In case if we generate non-HEAD version of package we should clean /usr/bin
  # as it will conflict with HEAD version of the package
  remove_binaries = (!suffix.nil? and !spec.executables.empty?)

  version_suffix = suffix ? '-' + suffix : ''
  params = {
    gem_name: spec.name,
    gem_ver: spec.version,
    version_suffix: version_suffix,
    website: spec.homepage, # TOTHINK: escape it?
    description: shell_escape_string(spec.summary),
    license: licenses.join(' '),
    arch: arch,
    sha1sum: sha1sum,
    depends: depends.join(' '),
    license_files: find_license_files(spec),
    maintainers: maintainers,
    contributors: contributors,
    remove_binaries: remove_binaries
  }

  content = Erubis::Eruby.new(PKGBUILD).result(params)
  return content, more
end

def create_packages(options)
  already_created = []
  packages = options.packages
  until packages.empty?
    name,version = *packages.pop
    pkg_name = 'ruby-' + name
    pkg_name += '-' + version if version
    next if already_created.include?(pkg_name)
    already_created << pkg_name

    Dir.mkdir(pkg_name) unless File.exist?(pkg_name)
    puts "Generate PKGBUILD for #{pkg_name}"

    pkgbuild_file = File.join(pkg_name, 'PKGBUILD')
    existing_pkgbuild = PkgBuild.new(pkgbuild_file)
    gem_path = download(name, version)
    (content,more) = gen_pkgbuild(gem_path, existing_pkgbuild, version)
    IO.write(pkgbuild_file, content)
    FileUtils.cp(gem_path, pkg_name)

    `git add #{pkgbuild_file} && git commit -m '#{pkg_name}: add'` if options.use_git
    existing_pkgbuild.makepackage if options.install  # TODO: check return value?

    if options.upload_aur
      uploaded = existing_pkgbuild.upload
      puts "Cannot upload changes for package #{existing_pkgbuild}" unless uploaded
    end

    # more - package that are absent and those that should be additionally generated
    packages += more
  end
end

if $0 == __FILE__
  options = parse_args(ARGV)

  @index = load_gem_index()
  `git stash save 'Save before running gem2arch'` if options.use_git

  if options.packages.empty?
    bump_packages(options)
  else
    create_packages(options)
  end
end
