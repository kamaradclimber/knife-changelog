require "knife/changelog/version"
require "berkshelf"
require 'chef/knife'
require 'mixlib/shellout'

class Chef
  class Knife
    class Changelog < Knife

      banner 'knife changelog COOKBOOK [COOKBOOK ...]'

      def initialize(options)
        super
        @tmp_prefix = 'knife-changelog'
        @berksfile = Berkshelf::Berksfile.from_options({})
        @tmp_dirs = []
      end

      option :linkify,
        :short => '-l',
        :long  => '--linkify',
        :description => 'add markdown links where relevant',
        :boolean => true

      option :ignore_changelog_file,
        :long => '--ignore-changelog-file',
        :description => "Ignore changelog file presence, use git history instead",
        :boolean => true

      def run
        begin
          @name_args.each do |cookbook|
            execute cookbook
          end
        ensure
          clean
        end
      end

      def clean
        @tmp_dirs.each do |dir|
          FileUtils.rm_r dir
        end
      end

      def ck_dep(name)
        @berksfile.lockfile.find(name)
      end

      def ck_location(name)
       ck_dep(name).location
      end

      def version_for(name)
        # FIXME uses public methods instead
        @berksfile.lockfile.graph.instance_variable_get(:@graph)[name].version
      end

      def execute(name)
        loc = ck_location(name)
        changelog = case loc
                    when NilClass
                      handle_source name, ck_dep(name)
                    when Berkshelf::GitLocation
                      handle_git loc
                    else
                      raise "Cannot handle #{loc.class} yet"
                    end
        print_changelog(name, changelog)
      end

      def print_changelog(name, changelog)
        unless changelog.empty?
          puts "--- Changelog for #{name} ---"
          puts changelog
          puts "-----------------"
        end
      end

      def handle_source(name, dep)
        ck = noauth_rest.get_rest("https://supermarket.getchef.com/api/v1/cookbooks/#{name}")
        url = ck['source_url'] || ck ['external_url']
        case url
        when nil
          fail "No external url for #{name}, can't find any changelog source"
        when /github.com\/(.*)(.git)?/
          options = {
            :github => $1,
            :revision => 'v' + version_for(name), 
          }
          location = Berkshelf::GithubLocation.new dep, options
          handle_git(location)
        else
          fail "External url #{url} points to unusable location!"
        end
      end

      def handle_git(location)
        tmp_dir = shallow_clone(@tmp_prefix,location.uri)

        rev_parse = location.instance_variable_get(:@rev_parse)
        cur_rev = location.revision.rstrip
        ls_tree = Mixlib::ShellOut.new("git ls-tree -r #{rev_parse}", :cwd => tmp_dir)
        ls_tree.run_command
        changelog = ls_tree.stdout.lines.find { |line| line =~ /\s(changelog.*$)/i }
        if changelog and not config[:ignore_changelog_file]
          puts "Found changelog file : " + $1
          generate_from_changelog_file($1, cur_rev, rev_parse, tmp_dir)
        else
          generate_from_git_history(tmp_dir, location, cur_rev, rev_parse)
        end
      end

      def generate_from_changelog_file(filename, current_rev, rev_parse, tmp_dir)
        diff = Mixlib::ShellOut.new("git diff #{current_rev}..#{rev_parse} -- #{filename}", :cwd => tmp_dir)
        diff.run_command
        diff.stdout.lines.collect {|line| $1 if line =~ /^\+([^+].*)/}.compact
      end

      def generate_from_git_history(tmp_dir, location, current_rev, rev_parse)
        log = Mixlib::ShellOut.new("git log --no-merges --abbrev-commit --pretty=oneline #{current_rev}..#{rev_parse}", :cwd => tmp_dir)
        log.run_command
        c = log.stdout
        n = short(location)
        c = linkify(n, c) if config[:linkify] and n
        c
      end

      def linkify(name, changelog)
        changelog = changelog.lines.map { |line|
          name + '@' + line # linfiky commits
        }
      end

      def short(location)
        if location.uri =~ /([\w-]+)\/([\w-]+)(\.git)?$/
          "%s/%s" % [$1,$2]
        end
      end

      def shallow_clone(tmp_prefix, uri)
        dir = Dir.mktmpdir(tmp_prefix)
        @tmp_dirs << dir
        clone = Mixlib::ShellOut.new("git clone --bare #{uri} bare-clone", :cwd => dir)
        clone.run_command
        ::File.join(dir, 'bare-clone')
      end

    end
  end
end
