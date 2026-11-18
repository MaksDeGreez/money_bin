module Receipts
  # Fills a card slip's own category suggestion (`suggested_category`, `suggested_category_confidence`;
  # docs/domain.md, "Card slip suggestions"). A slip has no items: it is booked as one line in one category, so its
  # suggestion comes from its merchant, the way a transaction's would.
  #
  #   Receipts::SuggestSlipCategory.call(receipt)  # => Result (:suggested, :failed, :skipped, :off)
  #
  # 1. The payee history (PayeeHistory): the payee the merchant name matches and the categories it was booked
  #    under, when they are consistent enough. `categoriser_model_name` becomes PayeeHistory::CATEGORISER_NAME.
  # 2. Otherwise the local transaction categoriser (MlClient#categorise_transactions), given the merchant name as
  #    the payee and the merchant, and the slip's total as an expense. `categoriser_model_name` becomes the model's
  #    name. The receipt's data goes to the local ML service only.
  #
  # The same guarantees as the items' suggestions (Receipts::SuggestCategories): with suggestions switched off
  # (CATEGORISE_BACKEND=off) it does nothing at all, since a suggestion on screen would pre-fill a slip labelled as
  # ground truth; it never writes `category_id` and never moves `lock_version` (update_columns); it only touches an
  # `extracted` card slip whose merchant is still the one asked about; a failure of the service never fails the
  # receipt, it records the error code in `categoriser_error` and keeps any earlier suggestion. When the suggestion
  # changes source on a slip whose category a person already chose, the receipt records
  # ReceiptGroundTruth::CATEGORISER_UNKNOWN (the pre-fill rule leans to leaving a receipt out).
  class SuggestSlipCategory
    Result = Data.define(:status, :source, :error)

    def self.call(receipt, client: MlClient.new)
      new(receipt, client:).call
    end

    def initialize(receipt, client: MlClient.new)
      @receipt = receipt
      @client = client
    end

    def call
      return Result.new(status: :off, source: nil, error: nil) unless ItemSuggestions.enabled?

      @receipt.reload
      merchant = @receipt.merchant_name.to_s.squish
      return Result.new(status: :skipped, source: nil, error: nil) unless @receipt.extracted? && @receipt.card_slip? && merchant.present?

      candidates = Categories::TransactionCandidates.all
      found = PayeeHistory.new(categories: candidates).lookup(merchant, except_transaction_id: @receipt.transaction_id)
      category_id, confidence, name, error =
        if found
          [ found.category_id, found.confidence, PayeeHistory::CATEGORISER_NAME, nil ]
        else
          ask_model(merchant, candidates)
        end
      written = write(merchant, category_id, confidence, name, error)
      LiveUpdate.changed(@receipt) if written
      status = error ? :failed : (written ? :suggested : :skipped)
      Result.new(status:, source: name, error:)
    end

    private
      def ask_model(merchant, candidates)
        text = merchant.first(Transactions::SuggestCategories::MAX_TEXT_LENGTH)
        amount = (-@receipt.total).to_s("F") if @receipt.total&.positive?
        features = { payee: text, merchant: text, amount:, currency: (@receipt.currency.presence if amount) }.compact
        answer = @client.categorise_transactions([ features ], categories: Categories::TransactionCandidates.payload(candidates))
        best = answer.results.first["candidates"].first
        category = candidates.find { |candidate| candidate.slug == best["category_slug"] }
        [ category.id, best["probability"].to_f.clamp(0.0, 1.0), answer.model_name, nil ]
      rescue MlClient::Error => error
        Rails.logger.warn("Receipts::SuggestSlipCategory: receipt #{@receipt.id}: the categoriser failed (#{error.code})")
        [ nil, nil, nil, error.code ]
      end

      # Returns whether the receipt was written.
      def write(merchant, category_id, confidence, name, error)
        @receipt.with_lock do
          next false unless @receipt.extracted? && @receipt.card_slip? && @receipt.merchant_name.to_s.squish == merchant

          attributes = { categorised_at: Time.current, categoriser_error: error }
          if category_id
            attributes.merge!(suggested_category_id: category_id, suggested_category_confidence: confidence,
              categoriser_model_name: categoriser_after(name))
          end
          @receipt.update_columns(attributes)
          true
        end
      end

      def categoriser_after(name)
        recorded = @receipt.categoriser_model_name.presence
        return name if recorded.nil? || recorded == name || @receipt.category_id.nil?

        ReceiptGroundTruth::CATEGORISER_UNKNOWN
      end
  end
end
