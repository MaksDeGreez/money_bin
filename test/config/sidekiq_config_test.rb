require "test_helper"
require "sidekiq/cli"

# config/sidekiq.yml read the way `sidekiq -C config/sidekiq.yml` reads it, into a fresh configuration (the
# process-wide one is left alone).
class SidekiqConfigTest < ActiveSupport::TestCase
  CONFIG_FILE = Rails.root.join("config/sidekiq.yml").to_s

  setup do
    @cli = Sidekiq::CLI.new
    @cli.config = Sidekiq::Config.new
    @cli.send(:setup_options, [ "-C", CONFIG_FILE, "-e", "test" ])
    @capsules = @cli.config.capsules
  end

  test "OCR and category suggestion jobs have a capsule of their own with one thread, suggestions first" do
    ocr = @capsules.fetch("ocr")

    assert_equal [ ReceiptCategoriseJob::QUEUE.to_s, ReceiptOcrJob::QUEUE.to_s ], ocr.queues
    assert_equal 1, ocr.concurrency
    assert_not ocr.weights.values.any?(&:positive?), "unweighted queues are strictly ordered" if ocr.respond_to?(:weights)
  end

  test "the OCR and suggestion jobs' queues are the OCR capsule's and no other" do
    [ ReceiptOcrJob, ReceiptCategoriseJob ].each do |job|
      assert_equal job::QUEUE.to_s, job.new.queue_name
      assert_equal [ "ocr" ], @capsules.select { |_name, capsule| capsule.queues.include?(job::QUEUE.to_s) }.keys
    end
  end

  test "the default capsule works the other queues" do
    assert_equal %w[default mailers], @capsules.fetch("default").queues
  end

  test "all threads together fit in the database connection pool" do
    threads = @capsules.each_value.sum(&:concurrency)
    pool = Integer(YAML.safe_load(ERB.new(Rails.root.join("config/database.yml").read).result, aliases: true)
      .dig("development", "max_connections"))

    assert_operator threads, :<=, pool
  end
end
