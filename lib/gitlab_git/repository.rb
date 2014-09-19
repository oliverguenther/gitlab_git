# Gitlab::Git::Repository is a wrapper around native Grit::Repository object
# We dont want to use grit objects inside app/
# It helps us easily migrate to rugged in future
require_relative 'encoding_helper'
require 'tempfile'

module Gitlab
  module Git
    class Repository
      include Gitlab::Git::Popen

      class NoRepository < StandardError; end

      # Default branch in the repository
      attr_accessor :root_ref

      # Full path to repo
      attr_reader :path

      # Directory name of repo
      attr_reader :name

      # Grit repo object
      attr_reader :grit

      # Rugged repo object
      attr_reader :rugged

      def initialize(path)
        @path = path
        @name = path.split("/").last
        @root_ref = discover_default_branch
      end

      def grit
        @grit ||= Grit::Repo.new(path)
      rescue Grit::NoSuchPathError
        raise NoRepository.new('no repository for such path')
      end

      # Alias to old method for compatibility
      def raw
        grit
      end

      def rugged
        @rugged ||= Rugged::Repository.new(path)
      rescue Rugged::RepositoryError, Rugged::OSError
        raise NoRepository.new('no repository for such path')
      end

      # Returns an Array of branch names
      # sorted by name ASC
      def branch_names
        branches.map(&:name)
      end

      # Returns an Array of Branches
      def branches
        rugged.branches.map do |rugged_ref|
          Branch.new(rugged_ref.name, rugged_ref.target)
        end.sort_by(&:name)
      end

      # Returns an Array of tag names
      def tag_names
        rugged.tags.map { |t| t.name }
      end

      # Returns an Array of Tags
      def tags
        rugged.refs.select do |ref|
          ref.name =~ /\Arefs\/tags/
        end.map do |rugged_ref|
          target = rugged_ref.target
          message = nil
          if rugged_ref.target.is_a?(Rugged::Tag::Annotation) &&
             rugged_ref.target.target.is_a?(Rugged::Commit)
            unless rugged_ref.target.target.message == rugged_ref.target.message
              message = rugged_ref.target.message.chomp
            end
          end
          Tag.new(rugged_ref.name, target, message)
        end.sort_by(&:name)
      end

      # Returns an Array of branch and tag names
      def ref_names
        branch_names + tag_names
      end

      # Deprecated. Will be removed in 5.2
      def heads
        @heads ||= grit.heads.sort_by(&:name)
      end

      def has_commits?
        !empty?
      end

      def empty?
        rugged.empty?
      end

      def repo_exists?
        !!rugged
      end

      # Discovers the default branch based on the repository's available branches
      #
      # - If no branches are present, returns nil
      # - If one branch is present, returns its name
      # - If two or more branches are present, returns current HEAD or master or first branch
      def discover_default_branch
        if branch_names.length == 0
          nil
        elsif branch_names.length == 1
          branch_names.first
        elsif rugged_head && branch_names.include?(Ref.extract_branch_name(rugged_head.name))
          Ref.extract_branch_name(rugged_head.name)
        elsif branch_names.include?("master")
          "master"
        else
          branch_names.first
        end
      end

      def rugged_head
        rugged.head
      rescue Rugged::ReferenceError
        nil
      end

      # Archive Project to .tar.gz
      #
      # Already packed repo archives stored at
      # app_root/tmp/repositories/project_name/project_name-commit-id.tag.gz
      #
      def archive_repo(ref, storage_path, format = "tar.gz")
        ref = ref || self.root_ref
        commit = Gitlab::Git::Commit.find(self, ref)
        return nil unless commit

        extension = nil
        git_archive_format = nil
        pipe_cmd = nil

        case format
        when "tar.bz2", "tbz", "tbz2", "tb2", "bz2"
          extension = ".tar.bz2"
          pipe_cmd = %W(bzip2)
        when "tar"
          extension = ".tar"
          pipe_cmd = %W(cat)
        when "zip"
          extension = ".zip"
          git_archive_format = "zip"
          pipe_cmd = %W(cat)
        else
          # everything else should fall back to tar.gz
          extension = ".tar.gz"
          git_archive_format = nil
          pipe_cmd = %W(gzip -n)
        end

        # Build file path
        file_name = self.name.gsub("\.git", "") + "-" + commit.id.to_s + extension
        file_path = File.join(storage_path, self.name, file_name)

        # Put files into a directory before archiving
        prefix = File.basename(self.name) + "/"

        # Create file if not exists
        unless File.exists?(file_path)
          # create archive in temp file
          tmp_file = Tempfile.new('gitlab-archive-repo', storage_path)
          self.grit.archive_to_file(ref, prefix, tmp_file.path, git_archive_format, pipe_cmd)

          # move temp file to persisted location
          FileUtils.mkdir_p File.dirname(file_path)
          FileUtils.move(tmp_file.path, file_path)

          # delte temp file
          tmp_file.close
          tmp_file.unlink
        end

        file_path
      end

      # Return repo size in megabytes
      def size
        size = popen(%W(du -s), path).first.strip.to_i
        (size.to_f / 1024).round(2)
      end

      def search_files(query, ref = nil)
        if ref.nil? || ref == ""
          ref = root_ref
        end

        greps = grit.grep(query, 3, ref)

        greps.map do |grep|
          Gitlab::Git::BlobSnippet.new(ref, grep.content, grep.startline, grep.filename)
        end
      end

      # Delegate log to Grit method
      #
      # Usage.
      #   repo.log(
      #     ref: 'master',
      #     path: 'app/models',
      #     limit: 10,
      #     offset: 5,
      #   )
      #
      def log(options)
        default_options = {
          limit: 10,
          offset: 0,
          path: nil,
          ref: root_ref,
          follow: false
        }

        options = default_options.merge(options)

        grit.log(
          options[:ref] || root_ref,
          options[:path],
          max_count: options[:limit].to_i,
          skip: options[:offset].to_i,
          follow: options[:follow]
        )
      end

      # Delegate commits_between to Grit method
      #
      def commits_between(from, to)
        grit.commits_between(from, to)
      end

      def merge_base_commit(from, to)
        grit.git.native(:merge_base, {}, [to, from]).strip
      end

      def diff(from, to, *paths)
        grit.diff(from, to, *paths)
      end

      # Return the diff between +from+ and +to+ in a single patch string.
      def diff_text(from, to, *paths)
        # NOTE: It would be simpler to use the Rugged::Diff#patch method, but
        # that formats the diff text differently than Rugged::Patch#to_s for
        # changes to binary files.
        rugged.diff(from, to, paths: paths).patches.map do |p|
          p.to_s
        end.join("\n")
      end

      # Returns commits collection
      #
      # Ex.
      #   repo.find_commits(
      #     ref: 'master',
      #     max_count: 10,
      #     skip: 5,
      #     order: :date
      #   )
      #
      #   +options+ is a Hash of optional arguments to git
      #     :ref is the ref from which to begin (SHA1 or name)
      #     :contains is the commit contained by the refs from which to begin (SHA1 or name)
      #     :max_count is the maximum number of commits to fetch
      #     :skip is the number of commits to skip
      #     :order is the commits order and allowed value is :date(default) or :topo
      #
      def find_commits(options = {})
        actual_options = options.dup

        allowed_options = [:ref, :max_count, :skip, :contains, :order]

        actual_options.keep_if do |key, value|
          allowed_options.include?(key)
        end

        default_options = {pretty: 'raw', order: :date}

        actual_options = default_options.merge(actual_options)

        order = actual_options.delete(:order)

        case order
        when :date
          actual_options[:date_order] = true
        when :topo
          actual_options[:topo_order] = true
        end

        ref = actual_options.delete(:ref)

        containing_commit = actual_options.delete(:contains)

        args = []

        if ref
          args.push(ref)
        elsif containing_commit
          args.push(*branch_names_contains(containing_commit))
        else
          actual_options[:all] = true
        end

        output = grit.git.native(:rev_list, actual_options, *args)

        Grit::Commit.list_from_string(grit, output).map do |commit|
          Gitlab::Git::Commit.decorate(commit)
        end
      rescue Grit::GitRuby::Repository::NoSuchShaFound
        []
      end

      # Returns branch names collection that contains the special commit(SHA1 or name)
      #
      # Ex.
      #   repo.branch_names_contains('master')
      #
      def branch_names_contains(commit)
        output = grit.git.native(:branch, {contains: true}, commit)

        # Fix encoding issue
        output = EncodingHelper::encode!(output)

        # The output is expected as follow
        #   fix-aaa
        #   fix-bbb
        # * master
        output.scan(/[^* \n]+/)
      end

      # Get refs hash which key is SHA1
      # and value is ref object(Grit::Head or Grit::Remote or Grit::Tag)
      def refs_hash
        # Initialize only when first call
        if @refs_hash.nil?
          @refs_hash = Hash.new { |h, k| h[k] = [] }

          grit.refs.each do |r|
            @refs_hash[r.commit.id] << r
          end
        end
        @refs_hash
      end

      # Lookup for rugged object by oid
      def lookup(oid)
        rugged.lookup(oid)
      end

      # Return hash with submodules info for this repository
      #
      # Ex.
      #   {
      #     "rack"  => {
      #       "id" => "c67be4624545b4263184c4a0e8f887efd0a66320",
      #       "path" => "rack",
      #       "url" => "git://github.com/chneukirchen/rack.git"
      #     },
      #     "encoding" => {
      #       "id" => ....
      #     }
      #   }
      #
      def submodules(ref)
        Grit::Submodule.config(grit, ref)
      end

      # Return total commits count accessible from passed ref
      def commit_count(ref)
        walker = Rugged::Walker.new(rugged)
        walker.sorting(Rugged::SORT_TOPO | Rugged::SORT_REVERSE)
        walker.push(ref)
        walker.count
      end

      # Sets HEAD to the commit specified by +ref+; +ref+ can be a branch or
      # tag name or a commit SHA.  Valid +reset_type+ values are:
      #
      #  [:soft]
      #    the head will be moved to the commit.
      #  [:mixed]
      #    will trigger a +:soft+ reset, plus the index will be replaced
      #    with the content of the commit tree.
      #  [:hard]
      #    will trigger a +:mixed+ reset and the working directory will be
      #    replaced with the content of the index. (Untracked and ignored files
      #    will be left alone)
      def reset(ref, reset_type)
        rugged.reset(ref, reset_type)
      end

      # Mimic the `git clean` command and recursively delete untracked files.
      # Valid keys that can be passed in the +options+ hash are:
      #
      # :d - Remove untracked directories
      # :f - Remove untracked directories that are managed by a different
      #      repository
      # :x - Remove ignored files
      #
      # The value in +options+ must evaluate to true for an option to take
      # effect.
      #
      # Examples:
      #
      #   repo.clean(d: true, f: true) # Enable the -d and -f options
      #
      #   repo.clean(d: false, x: true) # -x is enabled, -d is not
      def clean(options = {})
        strategies = [:remove_untracked]
        strategies.push(:force) if options[:f]
        strategies.push(:remove_ignored) if options[:x]

        # TODO: implement this method
      end

      # Check out the specified ref. Valid options are:
      #
      #  :b - Create a new branch at +start_point+ and set HEAD to the new
      #       branch.
      #
      #  * These options are passed to the Rugged::Repository#checkout method:
      #
      #  :progress ::
      #    A callback that will be executed for checkout progress notifications.
      #    Up to 3 parameters are passed on each execution:
      #
      #    - The path to the last updated file (or +nil+ on the very first
      #      invocation).
      #    - The number of completed checkout steps.
      #    - The number of total checkout steps to be performed.
      #
      #  :notify ::
      #    A callback that will be executed for each checkout notification
      #    types specified with +:notify_flags+. Up to 5 parameters are passed
      #    on each execution:
      #
      #    - An array containing the +:notify_flags+ that caused the callback
      #      execution.
      #    - The path of the current file.
      #    - A hash describing the baseline blob (or +nil+ if it does not
      #      exist).
      #    - A hash describing the target blob (or +nil+ if it does not exist).
      #    - A hash describing the workdir blob (or +nil+ if it does not
      #      exist).
      #
      #  :strategy ::
      #    A single symbol or an array of symbols representing the strategies
      #    to use when performing the checkout. Possible values are:
      #
      #    :none ::
      #      Perform a dry run (default).
      #
      #    :safe ::
      #      Allow safe updates that cannot overwrite uncommitted data.
      #
      #    :safe_create ::
      #      Allow safe updates plus creation of missing files.
      #
      #    :force ::
      #      Allow all updates to force working directory to look like index.
      #
      #    :allow_conflicts ::
      #      Allow checkout to make safe updates even if conflicts are found.
      #
      #    :remove_untracked ::
      #      Remove untracked files not in index (that are not ignored).
      #
      #    :remove_ignored ::
      #      Remove ignored files not in index.
      #
      #    :update_only ::
      #      Only update existing files, don't create new ones.
      #
      #    :dont_update_index ::
      #      Normally checkout updates index entries as it goes; this stops
      #      that.
      #
      #    :no_refresh ::
      #      Don't refresh index/config/etc before doing checkout.
      #
      #    :disable_pathspec_match ::
      #      Treat pathspec as simple list of exact match file paths.
      #
      #    :skip_locked_directories ::
      #      Ignore directories in use, they will be left empty.
      #
      #    :skip_unmerged ::
      #      Allow checkout to skip unmerged files (NOT IMPLEMENTED).
      #
      #    :use_ours ::
      #      For unmerged files, checkout stage 2 from index (NOT IMPLEMENTED).
      #
      #    :use_theirs ::
      #      For unmerged files, checkout stage 3 from index (NOT IMPLEMENTED).
      #
      #    :update_submodules ::
      #      Recursively checkout submodules with same options (NOT
      #      IMPLEMENTED).
      #
      #    :update_submodules_if_changed ::
      #      Recursively checkout submodules if HEAD moved in super repo (NOT
      #      IMPLEMENTED).
      #
      #  :disable_filters ::
      #    If +true+, filters like CRLF line conversion will be disabled.
      #
      #  :dir_mode ::
      #    Mode for newly created directories. Default: +0755+.
      #
      #  :file_mode ::
      #    Mode for newly created files. Default: +0755+ or +0644+.
      #
      #  :file_open_flags ::
      #    Mode for opening files. Default:
      #    <code>IO::CREAT | IO::TRUNC | IO::WRONLY</code>.
      #
      #  :notify_flags ::
      #    A single symbol or an array of symbols representing the cases in
      #    which the +:notify+ callback should be invoked. Possible values are:
      #
      #    :none ::
      #      Do not invoke the +:notify+ callback (default).
      #
      #    :conflict ::
      #      Invoke the callback for conflicting paths.
      #
      #    :dirty ::
      #      Invoke the callback for "dirty" files, i.e. those that do not need
      #      an update but no longer match the baseline.
      #
      #    :updated ::
      #      Invoke the callback for any file that was changed.
      #
      #    :untracked ::
      #      Invoke the callback for untracked files.
      #
      #    :ignored ::
      #      Invoke the callback for ignored files.
      #
      #    :all ::
      #      Invoke the callback for all these cases.
      #
      #  :paths ::
      #    A glob string or an array of glob strings specifying which paths
      #    should be taken into account for the checkout operation. +nil+ will
      #    match all files.  Default: +nil+.
      #
      #  :baseline ::
      #    A Rugged::Tree that represents the current, expected contents of the
      #    workdir.  Default: +HEAD+.
      #
      #  :target_directory ::
      #    A path to an alternative workdir directory in which the checkout
      #    should be performed.
      def checkout(ref, options = {}, start_point = "HEAD")
        if options[:b]
          rugged.branches.create(ref, start_point)
          @heads = nil
          options.delete(:b)
        end
        default_options = { strategy: :safe_create }
        rugged.checkout(ref, default_options.merge(options))
      end

      # Delete the specified branch from the repository
      def delete_branch(branch_name)
        rugged.branches.delete(branch_name)
        @heads = nil
      end

      # Return an array of this repository's remote names
      def remote_names
        rugged.remotes.each_name.to_a
      end

      # Delete the specified remote from this repository.
      def remote_delete(remote_name)
        rugged.remotes.delete(remote_name)
      end

      # Add a new remote to this repository.  Returns a Rugged::Remote object
      def remote_add(remote_name, url)
        rugged.remotes.create(remote_name, url)
      end

      # Update the specified remote using the values in the +options+ hash
      #
      # Example
      # repo.update_remote("origin", url: "path/to/repo")
      def remote_update(remote_name, options = {})
        # TODO: Implement other remote options
        remote = rugged.remotes[remote_name]
        remote.url = options[:url] if options[:url]
        remote.save
      end

      # Fetch the specified remote
      def fetch(remote_name)
        rugged.remotes[remote_name].fetch
      end

      # Push +*refspecs+ to the remote identified by +remote_name+.
      def push(remote_name, *refspecs)
        rugged.remotes[remote_name].push(refspecs)
      end

      # Return a String containing the mbox-formatted diff between +from+ and
      # +to+
      def format_patch(from, to)
        rugged.diff(from, to).patch
        from_sha = rugged.rev_parse_oid(from)
        to_sha = rugged.rev_parse_oid(to)
        commits_between(from_sha, to_sha).map do |commit|
          commit.to_mbox
        end.join("\n")
      end

      # Merge the +source_name+ branch into the +target_name+ branch. This is
      # equivalent to `git merge --no_ff +source_name+`, since a merge commit
      # is always created.
      def merge(source_name, target_name, options = {})
        our_commit = rugged.branches[target_name].target
        their_commit = rugged.branches[source_name].target

        raise "Invalid merge target" if our_commit.nil?
        raise "Invalid merge source" if their_commit.nil?

        merge_index = rugged.merge_commits(our_commit, their_commit)
        return false if merge_index.conflicts?

        actual_options = options.merge({
          parents: [our_commit, their_commit],
          tree: merge_index.write_tree(rugged),
          update_ref: "refs/heads/#{target_name}"
        })
        Rugged::Commit.create(rugged, actual_options)
      end

      private

      # Return the object that +revspec+ points to.  If +revspec+ is an
      # annotated tag, then return the tag's target instead.
      def rev_parse_target(revspec)
        obj = rugged.rev_parse(revspec)
        if obj.is_a?(Rugged::Tag::Annotation)
          obj.target
        else
          obj
        end
      end

      # Get the content of a blob for a given tree.  If the blob is a commit
      # (for submodules) then return the blob's OID.
      def blob_content(tree, blob_name)
        blob_hash = tree.find { |b| b[:name] == blob_name }

        if blob_hash[:type] == :commit
          blob_hash[:oid]
        else
          rugged.lookup(blob_hash[:oid]).content
        end
      end

      # Parses the contents of a .gitmodules file and returns a hash of
      # submodule information.
      def parse_gitmodules(tree, content)
        results = {}

        current = ""
        content.split("\n").each do |txt|
          if txt.match(/^\[/)
            current = txt.match(/(?<=").*(?=")/)[0]
            results[current] = {}
          else
            match_data = txt.match(/(\w+) = (.*)/)
            results[current][match_data[1]] = match_data[2]

            if match_data[1] == "path"
              results[current]["id"] = blob_content(tree, match_data[2])
            end
          end
        end

        results
      end

      # Return an array of log commits, given an SHA hash and a hash of
      # options.
      def build_log(sha, options)
        # Instantiate a Walker and add the SHA hash
        walker = Rugged::Walker.new(rugged)
        walker.push(sha)

        commits = []
        skipped = 0
        current_path = options[:path]

        walker.each do |c|
          break if options[:limit] > 0 && commits.length >= options[:limit]

          if !current_path ||
            commit_touches_path?(c, current_path, options[:follow])

            # This is a commit we care about, unless we haven't skipped enough
            # yet
            skipped += 1
            commits.push(c) if skipped > options[:offset]
          end
        end

        walker.reset

        commits
      end

      # Returns true if the given commit affects the given path.  If the
      # +follow+ option is true and the file specified by +path+ was renamed,
      # then the path value is set to the old path.
      def commit_touches_path?(commit, path, follow)
        if commit.parents.empty?
          diff = commit.diff
        else
          diff = commit.parents[0].diff(commit)
          diff.find_similar! if follow
        end

        # Check the commit's deltas to see if it touches the :path
        # argument
        diff.each_delta do |d|
          if path_matches?(path, d.old_file[:path], d.new_file[:path])
            if follow && d.renamed? && path == d.new_file[:path]
              # Look for the old path in ancestors
              path.replace(d.old_file[:path])
            end

            return true
          end
        end

        false
      end

      # Returns true if any of the strings in +*paths+ begins with the
      # +path_to_match+ argument
      def path_matches?(path_to_match, *paths)
        paths.any? do |p|
          p.match(/^#{Regexp.escape(path_to_match)}/)
        end
      end

      # Create an archive with the repository's files
      def create_archive(ref_name, pipe_cmd, file_path)
        # Put files into a prefix directory in the archive
        prefix = File.basename(self.name)
        extension = Pathname.new(file_path).extname

        if extension == ".zip"
          create_zip_archive(ref_name, file_path, prefix)
        else
          # Create a tarfile in memory
          tarfile = tar_string_io(ref_name, prefix)

          if extension == ".tar"
            File.new(file_path, "wb").write(tarfile.read)
          else
            compress_tar(tarfile, file_path, pipe_cmd)
          end
        end
      end

      # Return a StringIO with the contents of the repo's tar file
      def tar_string_io(ref_name, prefix)
        tarfile = StringIO.new
        Gem::Package::TarWriter.new(tarfile) do |tar|
          tar.mkdir(prefix, 33261)

          populated_index(ref_name).each do |entry|
            add_archive_entry(tar, prefix, entry)
          end
        end

        tarfile.rewind
        tarfile
      end

      # Create a zip file with the contents of the repo
      def create_zip_archive(ref_name, archive_path, prefix)
        Zip::File.open(archive_path, Zip::File::CREATE) do |zipfile|
          populated_index(ref_name).each do |entry|
            add_archive_entry(zipfile, prefix, entry)
          end
        end
      end

      # Add a file or directory from the index to the given tar or zip file
      def add_archive_entry(archive, prefix, entry)
        prefixed_path = File.join(prefix, entry[:path])
        content = rugged.lookup(entry[:oid]).content unless submodule?(entry)

        # Create a file in the archive for each index entry
        if archive.is_a?(Zip::File)
          unless submodule?(entry)
            archive.get_output_stream(prefixed_path) do |os|
              os.write(content)
            end
          end
        else
          if submodule?(entry)
            # Create directories for submodules
            archive.mkdir(prefixed_path, 33261)
          else
            # Write the blob contents to the file
            archive.add_file(prefixed_path, entry[:mode]) do |tf|
              tf.write(content)
            end
          end
        end
      end

      # Returns true if the index entry has the special file mode that denotes
      # a submodule.
      def submodule?(index_entry)
        index_entry[:mode] == 57344
      end

      # Send the +tar_string+ StringIO to +pipe_cmd+ for bzip2 or gzip
      # compression.
      def compress_tar(tar_string, file_path, pipe_cmd)
        # Write the in-memory tarfile to a pipe
        rd_pipe, rw_pipe = IO.pipe
        tar_pid = fork do
          rd_pipe.close
          rw_pipe.write(tar_string.read)
          rw_pipe.close
        end

        # Use the other end of the pipe to compress with bzip2 or gzip
        FileUtils.mkdir_p(Pathname.new(file_path).dirname)
        archive_file = File.new(file_path, "wb")
        rw_pipe.close
        compress_pid = spawn(*pipe_cmd, in: rd_pipe, out: archive_file)
        rd_pipe.close

        Process.waitpid(tar_pid)
        Process.waitpid(compress_pid)

        archive_file.close
        tar_string.close
      end

      # Return a Rugged::Index that has read from the tree at +ref_name+
      def populated_index(ref_name)
        tree = rugged.lookup(rugged.rev_parse_oid(ref_name)).tree
        index = rugged.index
        index.read_tree(tree)
        index
      end

      # Return an array of BlobSnippets for lines in +file_contents+ that match
      # +query+
      def build_greps(file_contents, query, ref, filename)
        greps = []

        file_contents.split("\n").each_with_index do |line, i|
          next unless line.match(/#{Regexp.escape(query)}/i)

          greps << Gitlab::Git::BlobSnippet.new(
            ref,
            file_contents.split("\n")[i - 3..i + 3],
            i - 2,
            filename
          )
        end

        greps
      end
    end
  end
end
