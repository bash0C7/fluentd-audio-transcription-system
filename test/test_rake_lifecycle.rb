# test/test_rake_lifecycle.rb
require 'test/unit'
require 'rake'
require 'fileutils'
require 'tmpdir'

class TestRakeLifecycle < Test::Unit::TestCase
  REPO_ROOT = File.expand_path('..', __dir__)

  def setup
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake.load_rakefile(File.join(REPO_ROOT, 'Rakefile'))
    @run_dir = File.join(REPO_ROOT, 'tmp', 'run')
    FileUtils.mkdir_p(@run_dir)
    @leftover_pids = []
  end

  def teardown
    @leftover_pids.each do |pid|
      Process.kill('KILL', pid) rescue nil
    end
  end

  def spawn_graceful(name)
    pidfile = File.join(@run_dir, "#{name}.pid")
    pid = Process.spawn('ruby', '-e', %(
      File.write(#{pidfile.inspect}, Process.pid)
      trap('TERM') { exit 0 }
      loop { sleep 0.1 }
    ))
    @leftover_pids << pid
    20.times { break if File.exist?(pidfile); sleep 0.1 }
    [pid, pidfile]
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def test_stop_via_pidfile_kills_graceful_process_and_removes_pidfile
    pid, pidfile = spawn_graceful('lifecycle-test')
    stop_via_pidfile('lifecycle-test', 5, has_screen: false)
    assert !alive?(pid), "process #{pid} should be dead after stop_via_pidfile"
    assert !File.exist?(pidfile), "pidfile should be removed"
  end

  def test_stop_via_pidfile_aborts_when_term_ignored
    pidfile = File.join(@run_dir, 'stubborn.pid')
    pid = Process.spawn('ruby', '-e', %(
      File.write(#{pidfile.inspect}, Process.pid)
      trap('TERM', 'IGNORE')
      loop { sleep 0.1 }
    ))
    @leftover_pids << pid
    20.times { break if File.exist?(pidfile); sleep 0.1 }

    assert_raise(SystemExit) do
      stop_via_pidfile('stubborn', 1, has_screen: false)
    end
    assert alive?(pid), "stubborn process must remain alive (no SIGKILL fallback)"
  end
end
