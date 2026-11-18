module Receipts
  # Fills the category suggestions of a receipt's items (docs/domain.md, "Category suggestions").
  #
  #   Receipts::SuggestCategories.call(receipt)  # => Receipts::SuggestCategories::Result
  #
  # 1. The label memory first (LabelMemory): an item whose normalised name the owner already labelled on another
  #    receipt, with a strict majority, gets that category, `suggested_by: "memory"`.
  # 2. The other items go to the ML service's /categorise in one call, with the candidate categories
  #    (Categories::ItemCandidates) and the shop's name; each gets the best candidate and its score,
  #    `suggested_by: "model"`.
  # 3. The receipt records `categoriser_model_name`, `categorised_at` and `categoriser_error` (nil when the
  #    service answered). `categoriser_model_name` names whose suggestions the items carry, for the pre-fill
  #    rule of the ground truth (docs/domain.md): the model's name when any item carries a model's suggestion,
  #    else LabelMemory::CATEGORISER_NAME when the label memory filled them all, else nil. A mix names the
  #    model: its test set must lose the receipt; the label memory, a rule over the owner's own labels, keeps
  #    it (the per-item source stays in `suggested_by`).
  #
  # What it never does:
  # - write `category_id` or `accepted_by_user`: a suggestion is only ever a suggestion, so nothing a person
  #   chose is overwritten (the item's suggestion fields are refreshed even where a category is chosen);
  # - fail the receipt: when the service cannot answer (down, a timeout, a 501 from a backend that does not
  #   categorise, an invalid answer), the memory's suggestions are still stored, the other items keep what
  #   they had, the receipt records the error code and stays `extracted`, and its page says so;
  # - move the receipt's `lock_version`: suggestions are not form fields, so a review form open meanwhile
  #   stays valid;
  # - touch a receipt that is not `extracted`, or a card slip (it has no items; the slip's own suggestion is
  #   left to the transaction-level categoriser).
  #
  # The writes happen in one database transaction with the receipt row locked, after the service answered
  # (outside the lock: a local model takes seconds). An item renamed or removed in the meantime is skipped,
  # and if the receipt is no longer `extracted` nothing is written. The open pages are refreshed
  # (Receipts::LiveUpdate).
  class SuggestCategories
    Result = Data.define(:status, :memory, :model, :error) do
      def self.skipped = new(status: :skipped, memory: 0, model: 0, error: nil)
    end

    Suggestion = Data.define(:category_id, :confidence, :source)

    def self.call(receipt, client: MlClient.new)
      new(receipt, client:).call
    end

    def initialize(receipt, client: MlClient.new)
      @receipt = receipt
      @client = client
    end

    def call
      @receipt.reload
      return Result.skipped unless @receipt.extracted?

      items = @receipt.items.to_a
      return Result.skipped if items.empty?

      candidates = Categories::ItemCandidates.all
      remembered = LabelMemory.new(categories: candidates).lookup(items.map(&:name), except_receipt: @receipt)
      from_memory, rest = items.partition { |item| remembered.key?(item.name_key) }
      suggestions = from_memory.to_h do |item|
        found = remembered.fetch(item.name_key)
        [ item.id, [ item.name_key, Suggestion.new(category_id: found.category_id, confidence: found.confidence, source: "memory") ] ]
      end
      model_name, error = ask_model(rest, candidates, suggestions) if rest.any?

      write(suggestions, model_name, error)
      LiveUpdate.changed(@receipt)
      model_count = suggestions.count { |_id, (_key, suggestion)| suggestion.source == "model" }
      Result.new(status: error ? :failed : :suggested, memory: from_memory.size, model: model_count, error:)
    end

    private
      # Adds the model's suggestions to `suggestions`; returns [model name, nil] or [nil, error code].
      def ask_model(items, candidates, suggestions)
        by_slug = candidates.index_by(&:slug)
        answer = @client.categorise(items.map(&:name), categories: Categories::ItemCandidates.payload(candidates),
          merchant: @receipt.merchant_name)
        items.zip(answer.results).each do |item, result|
          best = result["candidates"].first
          suggestion = Suggestion.new(category_id: by_slug.fetch(best["category_slug"]).id,
            confidence: best["score"].to_f.clamp(0.0, 1.0), source: "model")
          suggestions[item.id] = [ item.name_key, suggestion ]
        end
        [ answer.model_name, nil ]
      rescue MlClient::Error => error
        Rails.logger.warn("Receipts::SuggestCategories: receipt #{@receipt.id}: the categoriser failed (#{error.code})")
        [ nil, error.code ]
      end

      def write(suggestions, model_name, error)
        @receipt.with_lock do
          next unless @receipt.extracted?

          now = Time.current
          current = @receipt.items.reload.index_by(&:id)
          suggestions.each do |item_id, (name_key, suggestion)|
            item = current[item_id]
            next unless item && item.name_key == name_key

            item.update_columns(suggested_category_id: suggestion.category_id, confidence: suggestion.confidence,
              suggested_by: suggestion.source, updated_at: now)
          end
          @receipt.update_columns(categoriser_model_name: categoriser_after(model_name, error), categorised_at: now,
            categoriser_error: error)
        end
      end

      # Whose suggestions the items carry now: the model that answered, or (after a failure, or when the memory
      # answered everything) the model recorded before, while some item still carries a model's suggestion;
      # the label memory when only it suggested; nil when no item carries a suggestion.
      def categoriser_after(model_name, error)
        suggested = @receipt.items.where.not(suggested_category_id: nil)
        if suggested.where(suggested_by: "model").exists?
          recorded = @receipt.categoriser_model_name.presence
          (model_name unless error) || (recorded unless recorded == LabelMemory::CATEGORISER_NAME)
        elsif suggested.exists?
          LabelMemory::CATEGORISER_NAME
        end
      end
  end
end
