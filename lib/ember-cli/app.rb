require "timeout"
require "json"

module EmberCLI
  class App
    ADDON_VERSION = "0.0.11"
    EMBER_CLI_VERSION = "~> 0.1.5", "~> 0.2.0"

    class BuildError < StandardError; end

    attr_reader :name, :options, :paths, :pid

    delegate :root, to: :paths

    def initialize(name, options={})
      @name, @options = name.to_s, options
      @paths = PathSet.new(self)
    end

    def compile
      @compiled ||= begin
        prepare(env: :compile)
        silence_build { exec command }
        if use_ember_fingerprints
          copy_fingerprinted_assets
          fixup_asset_manifest
        end
        check_for_build_error!
        true
      end
    end

    def install_dependencies
      exec "#{bundler_path} install" if gemfile_path.exist?
      exec "#{npm_path} install"
    end

    def run
      prepare(env: :run)
      FileUtils.touch lockfile_path
      cmd = command(watch: true)
      @pid = exec(cmd, method: :spawn)
      Process.detach pid
      set_on_exit_callback
    end

    def run_tests
      prepare(env: :test)
      tests_pass = exec("#{ember_path} test")
      exit 1 unless tests_pass
    end

    def stop
      Process.kill :INT, pid if pid
      @pid = nil
    end

    def exposed_js_assets
      %W[#{name}/vendor #{name}/#{ember_app_name}]
    end

    def exposed_css_assets
      %W[#{name}/vendor #{name}/#{ember_app_name}]
    end

    def wait
      Timeout.timeout(build_timeout) do
        wait_for_build_complete_or_error
      end
    rescue Timeout::Error
      suggested_timeout = build_timeout + 5

      warn <<-MSG.strip_heredoc
        ============================= WARNING! =============================

          Seems like Ember #{name} application takes more than #{build_timeout}
          seconds to compile.

          To prevent race conditions consider adjusting build timeout
          configuration in your ember initializer:

            EmberCLI.configure do |config|
              config.build_timeout = #{suggested_timeout} # in seconds
            end

          Alternatively, you can set build timeout per application like this:

            EmberCLI.configure do |config|
              config.app :#{name}, build_timeout: #{suggested_timeout}
            end

        ============================= WARNING! =============================
      MSG
    end

    def method_missing(method_name, *)
      if path_method = supported_path_method(method_name)
        paths.public_send(path_method)
      else
        super
      end
    end

    def respond_to_missing?(method_name, *)
      if supported_path_method(method_name)
        true
      else
        super
      end
    end

    private

    def set_on_exit_callback
      @on_exit_callback ||= at_exit{ stop }
    end

    def supported_path_method(original)
      path_method = original.to_s[/\A(.+)_path\z/, 1]
      path_method if path_method && paths.respond_to?(path_method)
    end

    def silence_build(&block)
      if ENV.fetch("EMBER_CLI_RAILS_VERBOSE"){ EmberCLI.env.production? }
        yield
      else
        silence_stream STDOUT, &block
      end
    end

    def build_timeout
      options.fetch(:build_timeout){ EmberCLI.configuration.build_timeout }
    end

    def check_for_build_error!
      raise_build_error! if build_error?
    end

    def reset_build_error!
      build_error_file_path.delete if build_error?
    end

    def build_error?
      build_error_file_path.exist?
    end

    def raise_build_error!
      error = BuildError.new("EmberCLI app #{name.inspect} has failed to build")
      error.set_backtrace build_error_file_path.read.split(?\n)
      fail error
    end

    def prepare(params={})
      @prepared ||= begin
        check_addon!
        check_ember_cli_version!
        reset_build_error!
        unless use_ember_fingerprints && params[:env] && params[:env] == :compile
          symlink_to_assets_root
          add_assets_to_precompile_list
        end
        true
      end
    end

    def copy_fingerprinted_assets
      FileUtils.rm_rf "#{Rails.root}/public/assets/#{name}"
      FileUtils.mkdir_p "#{Rails.root}/public/assets/#{name}"
      FileUtils.cp_r Dir["#{dist_path.join("assets")}/*"], "#{Rails.root}/public/assets/#{name}/"
    end

    def fixup_asset_manifest
      # Add the app name to the file & asset paths (e.g. /frontend/vendor-12345.js)
      app_manifest_file = Dir["#{Rails.root.join('public/assets').join(name)}/manifest*.json"].first
      app_manifest = JSON.parse(File.read(app_manifest_file))

      app_manifest["files"] = app_manifest["files"].inject({}) do |new_files, pair|
        file,info = pair
        info = info.merge( "logical_path" => "#{name}/#{info['logical_path']}" )
        new_files["#{name}/#{file}"] = info
        new_files
      end

      app_manifest["assets"] = app_manifest["assets"].inject({}) do |new_assets, pair|
        file,fingerprinted_file = pair
        new_assets["#{name}/#{file}"] = "#{name}/#{fingerprinted_file}"
        new_assets
      end

      merge_asset_manifest( app_manifest )
    end

    def merge_asset_manifest( app_manifest )
      # Merge with the manifest file in the root for the case of multiple apps
      main_manifest_file = "#{Rails.root}/public/assets/manifest.json"

      if File.exists? main_manifest_file
        main_manifest = JSON.parse( File.read( main_manifest_file ) )
        ["files","assets"].each do |mapping|
          main_manifest[mapping] = main_manifest[mapping].merge( app_manifest[mapping] )
        end
      else
        main_manifest = app_manifest
      end

      # Write manifest file to the root where Rails will pick it up and merge with it
      File.open( main_manifest_file, "w" ) do |file|
        file.write( main_manifest.to_json )
      end
    end

    def check_ember_cli_version!
      version = dev_dependencies.fetch("ember-cli").split(?-).first

      unless Helpers.match_version?(version, EMBER_CLI_VERSION)
        fail <<-MSG.strip_heredoc
          EmberCLI Rails require ember-cli NPM package version to be
          #{EMBER_CLI_VERSION} to work properly. From within your EmberCLI directory
          please update your package.json accordingly and run:

            $ npm install

        MSG
      end
    end

    def check_addon!
      unless addon_present?
        fail <<-MSG.strip_heredoc
          EmberCLI Rails requires your Ember app to have an addon.

          From within your EmberCLI directory please run:

            $ npm install --save-dev ember-cli-rails-addon@#{ADDON_VERSION}

          in you Ember application root: #{root}
        MSG
      end
    end

    def symlink_to_assets_root
      assets_path.join(name).make_symlink dist_path.join("assets")
    rescue Errno::EEXIST
      # Sometimes happens when starting multiple Unicorn workers.
      # Ignoring...
    end

    def add_assets_to_precompile_list
      Rails.configuration.assets.precompile << /\A#{name}\//
    end

    def command(options={})
      watch = options[:watch] ? "--watch" : ""
      "#{ember_path} build #{watch} --environment #{environment} --output-path #{dist_path} #{log_pipe}"
    end

    def log_pipe
      "| #{tee_path} -a #{log_path}" if tee_path
    end

    def ember_app_name
      @ember_app_name ||= options.fetch(:name){ package_json.fetch(:name) }
    end

    def environment
      EmberCLI.env.production?? "production" : "development"
    end

    def package_json
      @package_json ||= JSON.parse(package_json_file_path.read).with_indifferent_access
    end

    def dev_dependencies
      package_json.fetch("devDependencies", {})
    end

    def addon_present?
      dev_dependencies["ember-cli-rails-addon"] == ADDON_VERSION &&
        addon_package_json_file_path.exist?
    end

    def excluded_ember_deps
      Array.wrap(options[:exclude_ember_deps]).join(?,)
    end

    def use_ember_fingerprints
      options.fetch(:use_ember_fingerprints){ false }
    end

    def env_hash
      ENV.clone.tap do |vars|
        vars.store "DISABLE_FINGERPRINTING", (!use_ember_fingerprints).to_s
        vars.store "RAILS_ENV", Rails.env
        vars.store "EXCLUDE_EMBER_ASSETS", excluded_ember_deps
        vars.store "BUNDLE_GEMFILE", gemfile_path.to_s if gemfile_path.exist?
      end
    end

    def exec(cmd, options={})
      method_name = options.fetch(:method, :system)

      Dir.chdir root do
        Kernel.public_send(method_name, env_hash, cmd, err: :out)
      end
    end

    def wait_for_build_complete_or_error
      loop do
        check_for_build_error!
        break unless lockfile_path.exist?
        sleep 0.1
      end
    end
  end
end
