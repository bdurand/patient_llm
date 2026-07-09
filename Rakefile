begin
  require "bundler/setup"
rescue LoadError
  puts "You must `gem install bundler` and `bundle install` to run rake tasks"
end

require "bundler/gem_tasks"

task :verify_release_branch do
  unless `git rev-parse --abbrev-ref HEAD`.chomp == "main"
    warn "Gem can only be released from the main branch"
    exit 1
  end
end

Rake::Task[:release].enhance([:verify_release_branch])

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc "Start a valkey container for testing running on port 24456"
task :valkey do
  exec "exec bin/run-valkey"
end

desc "Run the test application for manual testing"
task test_app: "test_app:start"

namespace :test_app do
  desc "Start the test application"
  task :start do
    Bundler.with_unbundled_env do
      ENV["BUNDLE_GEMFILE"] = File.expand_path("test_app/Gemfile", __dir__)
      Dir.chdir("test_app") do
        exec "ruby server"
      end
    end
  end

  desc "Stop the running test application on default port 9292 or PORT env var"
  task :stop do
    port = ENV.fetch("PORT", "9393").to_i
    pids = `lsof -ti :#{port}`.split("\n").map(&:strip).reject(&:empty?)

    if pids.empty?
      puts "No running test application found (port #{port} is not in use)"
    else
      pids.each do |pid|
        puts "Killing process #{pid}..."
        system("kill #{pid}")
      end

      process_died = false
      20.times do
        process_died = `lsof -ti :#{port}`.split("\n").map(&:strip).reject(&:empty?).empty?
        break if process_died

        sleep(0.25)
      end

      unless process_died
        pids.each { |pid| system("kill -9 #{pid}") unless process_died }
      end

      puts "Test application stopped"
    end
  end

  desc "Open an interactive console with test application loaded"
  task :console do
    Bundler.with_unbundled_env do
      ENV["BUNDLE_GEMFILE"] = File.expand_path("test_app/Gemfile", __dir__)
      exec "cd test_app && ruby console"
    end
  end

  desc "Install bundle for the test application"
  task :bundle do
    Bundler.with_unbundled_env do
      ENV["BUNDLE_GEMFILE"] = File.expand_path("test_app/Gemfile", __dir__)
      exec "cd test_app && bundle install"
    end
  end

  namespace :bundle do
    desc "Update bundle for the test application"
    task :update do
      Bundler.with_unbundled_env do
        exec("bundle", "update", chdir: File.expand_path("test_app", __dir__))
      end
    end
  end
end
