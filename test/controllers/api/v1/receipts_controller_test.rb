require "test_helper"

module Api
  module V1
    class ReceiptsControllerTest < ActionDispatch::IntegrationTest
      include OpenapiTestHelper
      include ApiRequestTestHelper

      test "lists receipts newest first in the documented shape, without items" do
        api_get api_v1_receipts_path

        assert_response :success
        assert_api_conform(200)
        assert_equal [ receipts(:new_receipt), receipts(:corner_receipt), receipts(:market_receipt) ].map(&:id), json["receipts"].pluck("id")
        assert_equal({
          "id" => receipts(:market_receipt).id, "status" => "reviewed", "merchant" => "Example Market",
          "issued_at" => "2026-10-03T18:40:00+03:00", "issued_on" => "2026-10-03", "total" => "1250.40", "currency" => "UAH",
          "transaction_id" => transactions(:market_split).id, "items_count" => 3
        }, json["receipts"].last)
        assert_nil json["next_cursor"]
      end

      test "filters by status and pages with next_cursor" do
        api_get api_v1_receipts_path, params: { status: "reviewed" }
        assert_api_conform(200)
        assert_equal [ receipts(:market_receipt).id ], json["receipts"].pluck("id")

        api_get api_v1_receipts_path, params: { limit: 2 }
        assert_api_conform(200)
        assert_equal 2, json["receipts"].size

        api_get api_v1_receipts_path, params: { limit: 2, cursor: json["next_cursor"] }
        assert_api_conform(200)
        assert_equal [ receipts(:market_receipt).id ], json["receipts"].pluck("id")
        assert_nil json["next_cursor"]
      end

      test "one receipt with its items, categories and suggestions" do
        api_get api_v1_receipt_path(receipts(:corner_receipt))

        assert_api_conform(200)
        assert_equal [ "extracted", "Corner Shop", "152.50", "152.50", nil, 3 ],
          json.values_at("status", "merchant", "total", "items_total", "transaction_id", "items_count")
        sandwich = json["items"].find { |item| item["name"] == "Sandwich" }
        assert_equal({
          "id" => receipt_items(:corner_sandwich).id, "position" => 2, "name" => "Sandwich", "quantity" => "1.000",
          "unit_price" => "95.00", "amount" => "95.00", "discount" => "0.00", "category" => nil,
          "suggested_category" => { "id" => categories(:takeaway).id, "slug" => "eating-out/takeaway-fast-food", "name" => "Takeaway & fast food" },
          "confidence" => 0.62, "accepted_by_user" => false
        }, sandwich)
        assert_equal [ 1, 2, 3 ], json["items"].pluck("position")
        assert_equal "-2.50", json["items"].last["amount"]
        assert_no_floats(json)
      end

      test "a receipt with no OCR yet has empty fields and no items" do
        api_get api_v1_receipt_path(receipts(:new_receipt))

        assert_api_conform(200)
        assert_equal [ "uploaded", nil, nil, nil, "0.00", [] ], json.values_at("status", "merchant", "issued_at", "total", "items_total", "items")
      end

      test "the JSON never carries the photos, the OCR answer or the fingerprint" do
        api_get api_v1_receipt_path(receipts(:market_receipt))

        assert_api_conform(200)
        assert_empty json.keys & %w[images ocr_raw sha256 qr_payload]
      end

      test "an unknown id is 404; a bad parameter is 422" do
        api_get "/api/v1/receipts/999999999"
        assert_response :not_found
        assert_api_response_conform(404)

        api_get api_v1_receipts_path, params: { status: "done" }
        assert_invalid_parameter("status")

        api_get api_v1_receipts_path, params: { cursor: KeysetCursor.encode("2026-10-03", 1) }
        assert_invalid_parameter("cursor")

        api_get api_v1_receipt_path(receipts(:market_receipt)), params: { with: "images" }
        assert_invalid_parameter("with")
      end
    end
  end
end
