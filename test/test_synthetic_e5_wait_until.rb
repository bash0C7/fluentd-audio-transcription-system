# test/test_synthetic_e5_wait_until.rb
#
# Unit specs for the condition-based-waiting helper used by SyntheticE5
# to replace fixed `sleep 5` / `sleep 30` calls. The mini-E5 task is an
# integration test against real spawned processes so it can only be
# verified end-to-end; this file pins the behavior of the wait primitive
# in isolation so the integration scaffolding stays trustworthy.
require 'test/unit'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'lib', 'audio_transcription', 'synthetic_e5')

class TestSyntheticE5WaitUntil < Test::Unit::TestCase
  def setup
    @e5 = AudioTranscription::SyntheticE5.new
  end

  def test_wait_until_returns_true_immediately_when_condition_already_holds
    started = Time.now
    result = @e5.send(:wait_until, timeout: 5.0, poll: 0.5) { true }
    elapsed = Time.now - started
    assert_equal true, result
    assert_operator elapsed, :<, 0.1, 'must short-circuit without sleeping'
  end

  def test_wait_until_returns_false_when_timeout_elapses_with_condition_never_true
    started = Time.now
    result = @e5.send(:wait_until, timeout: 0.3, poll: 0.05) { false }
    elapsed = Time.now - started
    assert_equal false, result
    assert_operator elapsed, :>=, 0.3,
                    "must wait at least the full timeout when condition is never satisfied (elapsed=#{elapsed})"
    assert_operator elapsed, :<, 1.0,
                    "must not block far past the timeout (elapsed=#{elapsed})"
  end

  def test_wait_until_returns_true_after_condition_flips_during_polling
    flips_after = Time.now + 0.2
    result = @e5.send(:wait_until, timeout: 2.0, poll: 0.05) { Time.now >= flips_after }
    assert_equal true, result
  end
end
