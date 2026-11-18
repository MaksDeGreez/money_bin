require "test_helper"

# What a person types into the review form, manual entry and the check of a tax-service record never reaches
# the request log.
class FilterParametersTest < ActiveSupport::TestCase
  test "the review form and manual entry parameters are filtered, other parameters are not" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    params = { "receipt" => { "merchant_name" => "Corner Shop", "card_last4" => "4242" },
               "manual_expense" => { "payee_name" => "Corner Shop" }, "ground_truth_check" => { "note" => "Corner Shop" },
               "intent" => "save", "status" => "extracted", "outcome" => "matches" }

    assert_equal({ "receipt" => "[FILTERED]", "manual_expense" => "[FILTERED]", "ground_truth_check" => "[FILTERED]",
                   "intent" => "save", "status" => "extracted", "outcome" => "matches" },
      filter.filter(params))
  end
end
