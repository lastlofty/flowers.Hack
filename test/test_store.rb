# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../app/store'
require_relative '../lib/paybridge'

class TestStore < Minitest::Test
  def setup
    @root = Dir.mktmpdir('paybridge_store_')
    @generation = Paybridge.generate(
      spec_path: File.expand_path('../examples/provider_api.yaml', __dir__), provider: 'novapay'
    )
  end

  def teardown
    FileUtils.remove_entry(@root) if Dir.exist?(@root)
  end

  def test_restores_metadata_model_and_verification_after_restart
    store = Paybridge::Store.new(@root)
    integration = store.save(@generation)
    store.save_verification(integration, status: 'partial', passed: 2, failed: 0, skipped: 1,
                                         checked_at: '2026-09-05T00:00:00Z', cases: [])

    restored = Paybridge::Store.new(@root).find(integration.id)
    assert_equal integration.id, restored.id
    assert_equal 'novapay', restored.model['provider']
    assert_equal 'partial', restored.verification['status']
    assert_equal integration.files, restored.files
  end

  def test_metadata_is_not_downloadable_or_in_archive_list
    store = Paybridge::Store.new(@root)
    integration = store.save(@generation)
    refute_includes integration.files, Paybridge::Store::METADATA_FILE
    assert_nil store.file(integration, '../metadata.json')
    assert_nil store.file(integration, Paybridge::Store::METADATA_FILE)
  end

  def test_corrupt_or_incomplete_record_does_not_break_restart
    broken = File.join(@root, 'int_000000000000000000000000')
    FileUtils.mkdir_p(broken)
    File.write(File.join(broken, Paybridge::Store::METADATA_FILE), '{broken')

    store = Paybridge::Store.new(@root, logger: LoggerStub.new)
    assert_nil store.find('int_000000000000000000000000')
  end

  class LoggerStub
    def warn(_message); end
  end
end
