require "test_helper"
require "open3"

# The repository will be public: secrets, personal data, uploads and model weights must stay out of git
# (.gitignore). The paths below do not need to exist; git checks them against the ignore rules.
class GitignoreTest < ActiveSupport::TestCase
  IGNORED = %w[
    .env .env.local .env.development ml/.env
    config/master.key config/credentials/production.key config/credentials/development.key
    storage/ab/cd/abcdef data/receipts.csv ml/data/sample.jpg
    ml/models/weights.safetensors model.gguf model.bin model.pt model.pth model.h5 checkpoints/last.ckpt
    model.onnx model.mlx arrays.npz
  ].freeze
  KEPT = %w[ .env.example config/credentials.yml.enc config/credentials/production.yml.enc ].freeze

  test "secrets, personal data and model weights are ignored" do
    not_ignored = IGNORED.reject { |path| ignored?(path) }

    assert_empty not_ignored, "not ignored by .gitignore"
  end

  test "the sample settings and encrypted credentials are not ignored" do
    assert_empty KEPT.select { |path| ignored?(path) }, "ignored by .gitignore"
  end

  private
    def ignored?(path)
      _out, status = Open3.capture2e("git", "check-ignore", "-q", "--no-index", path, chdir: Rails.root.to_s)
      raise "git check-ignore failed for #{path}" if status.exitstatus > 1

      status.success?
    end
end
