module Transactions
  # Scores every uncategorised transaction line with the transaction categoriser and stores the suggestion on
  # the line (docs/domain.md, "Transaction suggestions").
  #
  #   Transactions::SuggestCategories.call(run)  # run: a TransactionSuggestionRun; returns it, finished
  #
  # - Which lines: those with no category or the taxonomy's Uncategorised, on transactions that are not transfer
  #   legs, whose stored suggestion is missing or was made by another artefact than the one the ML service serves
  #   now. So a new artefact refreshes every suggestion, and a second run with the same artefact asks nothing.
  # - How: the transactions go to POST /categorise/transaction in batches of BATCH (thousands of lines are a few
  #   dozen calls, never one per row), with the app's category list (Categories::TransactionCandidates). A
  #   transaction with no text and no MCC cannot be scored and is counted as skipped.
  # - What it writes: the suggestion columns of the still-uncategorised lines (best category and probability,
  #   runner-up, source, artefact, time), with update_all: never a category, an amount or a transaction's
  #   lock_version, so a person editing meanwhile is never disturbed and a line categorised meanwhile keeps no
  #   new suggestion.
  # - The transaction data goes to the local ML service only, which runs the model on this machine
  #   (ml/README.md, "The transaction categoriser").
  # - A failure of the service is recorded on the run (its code), never raised: the person starts a new run.
  class SuggestCategories
    BATCH = 200
    MAX_TEXT_LENGTH = 500

    def self.call(run, client: MlClient.new)
      new(run, client:).call
    end

    # The transactions with an uncategorised line whose suggestion is missing or from another artefact.
    def self.pending_transaction_ids(model_version)
      TransactionLine.uncategorised.joins(:parent).where(transactions: { transfer_id: nil })
        .where("transaction_lines.suggestion_model_version IS DISTINCT FROM ?", model_version)
        .distinct.order(:transaction_id).pluck(:transaction_id)
    end

    # What the categoriser reads of one transaction (ml/README.md): texts cut to the service's limit, the amount as
    # a decimal string, never a Float.
    def self.features(transaction)
      {
        payee: text(transaction.payee&.name), comment: text(transaction.comment),
        bank_description: text(transaction.bank_description), merchant: text(transaction.merchant),
        mcc: transaction.mcc.presence, amount: transaction.amount.to_s("F"), currency: transaction.account.currency,
        account_kind: transaction.account.kind
      }
    end

    def self.text(value)
      value.to_s.squish.first(MAX_TEXT_LENGTH).presence
    end

    def self.scorable?(features)
      features.values_at(:payee, :comment, :bank_description, :merchant, :mcc).any?(&:present?)
    end

    def initialize(run, client: MlClient.new)
      @run = run
      @client = client
    end

    def call
      @run.update!(status: "running", started_at: Time.current, error: nil)
      version = @client.transaction_categoriser.model_version
      ids = self.class.pending_transaction_ids(version)
      @run.update!(model_version: version, total_count: ids.size)
      candidates = Categories::TransactionCandidates.all
      by_slug = candidates.index_by(&:slug)
      payload = Categories::TransactionCandidates.payload(candidates)
      ids.each_slice(BATCH) { |batch| score(batch, version, by_slug, payload) }
      @run.update!(status: "done", finished_at: Time.current)
      @run
    rescue MlClient::Error => error
      Rails.logger.warn("Transactions::SuggestCategories: the transaction categoriser failed (#{error.code})")
      @run.update!(status: "failed", error: error.code, finished_at: Time.current)
      @run
    end

    private
      def score(ids, version, by_slug, payload)
        transactions = Transaction.includes(:payee, :account).where(id: ids).order(:id).to_a
        features = transactions.to_h { |transaction| [ transaction.id, self.class.features(transaction) ] }
        scorable = transactions.select { |transaction| self.class.scorable?(features[transaction.id]) }
        if scorable.any?
          answer = @client.categorise_transactions(scorable.map { |transaction| features[transaction.id] }, categories: payload)
          now = Time.current
          scorable.zip(answer.results).each { |transaction, result| write(transaction, result, answer.model_version, by_slug, now) }
        end
        @run.update!(scored_count: @run.scored_count + scorable.size,
          skipped_count: @run.skipped_count + transactions.size - scorable.size)
      end

      def write(transaction, result, version, by_slug, now)
        best, runner_up = result["candidates"]
        TransactionLine.uncategorised.where(transaction_id: transaction.id).update_all(
          suggested_category_id: by_slug.fetch(best["category_slug"]).id,
          suggestion_probability: best["probability"].to_f.clamp(0.0, 1.0),
          runner_up_category_id: runner_up && by_slug.fetch(runner_up["category_slug"]).id,
          runner_up_probability: runner_up && runner_up["probability"].to_f.clamp(0.0, 1.0),
          suggestion_source: result["source"], suggestion_model_version: version, suggested_at: now
        )
      end
  end
end
