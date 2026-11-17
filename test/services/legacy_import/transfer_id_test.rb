require "test_helper"

module LegacyImport
  class TransferIdTest < ActiveSupport::TestCase
    # Computed independently with Python: uuid.uuid5(uuid.UUID(NAMESPACE), "T-0001").
    test "is the RFC UUID version 5 of the key under the fixed namespace" do
      assert_equal "bdf1a284-e14e-4f36-a890-6310852e90d7", TransferId::NAMESPACE
      assert_equal "43964848-67ea-5091-9e0c-5e1e8235a3e2", TransferId.for("T-0001")
      assert_equal "e2419435-eed0-5b58-8d91-df6579048a00", TransferId.for("T-0002")
    end

    test "the same key always gives the same id" do
      assert_equal TransferId.for("any key"), TransferId.for("any key")
      assert_not_equal TransferId.for("any key"), TransferId.for("any key ")
    end
  end
end
