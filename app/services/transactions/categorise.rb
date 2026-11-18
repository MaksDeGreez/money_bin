module Transactions
  # Sets the category of uncategorised lines of one transaction, as a person decided on the transactions list
  # (one line at a time) or by confirming a bulk acceptance (docs/domain.md, "Transaction suggestions").
  #
  #   Transactions::Categorise.call(transaction_id, lock_version: 7, choices: [
  #     Transactions::Categorise::Choice.new(line_id: 12, category_id: 5, origin: "suggestion", probability: 0.93,
  #       model_version: "2026-11-18-0123456789ab")
  #   ])  # => Result with status :categorised, :stale, :changed or :invalid
  #
  # The rules:
  # - Only an uncategorised line (no category, or Uncategorised) is ever written: a category a person (or anything
  #   else) chose is never overwritten. A line that has a category by now is :changed and nothing is written.
  # - `lock_version` is the transaction's version the person saw (the list row, or the bulk preview). The
  #   transaction row is locked (SELECT ... FOR UPDATE) and compared with it; a newer version is :stale and
  #   nothing is written, so an edit made meanwhile always wins.
  # - The lines are written through their transaction (nested autosave), so the model's rules run: a line must be
  #   a category (not a group), the sum is untouched, the save bumps lock_version.
  # - The status follows Transaction#status_after_categorising: `needs_review` becomes `confirmed` once no line is
  #   uncategorised and no other reason remains; a draft stays a draft.
  # - The provenance goes on each line: `category_origin` (`person`, `suggestion` or `bulk`) and, for a taken
  #   suggestion, its probability and artefact.
  #
  # All in one database transaction (a savepoint inside a caller's), so a refusal writes nothing.
  class Categorise
    Choice = Data.define(:line_id, :category_id, :origin, :probability, :model_version)
    Result = Data.define(:status, :transaction) do
      def categorised? = status == :categorised
    end

    def self.call(transaction_id, lock_version:, choices:)
      new(transaction_id, lock_version:, choices:).call
    end

    def initialize(transaction_id, lock_version:, choices:)
      @transaction_id = transaction_id
      @lock_version = Integer(lock_version)
      @choices = Array(choices)
    end

    def call
      transaction = nil
      status = Transaction.transaction(requires_new: true) do
        transaction = Transaction.lock.includes(:receipt, lines: :category).find_by(id: @transaction_id)
        outcome = check(transaction)
        next outcome if outcome

        apply(transaction)
        :categorised
      end
      Result.new(status:, transaction:)
    rescue ActiveRecord::StaleObjectError
      Result.new(status: :stale, transaction:)
    end

    private
      def check(transaction)
        return :changed if transaction.nil? || transaction.transfer_leg?
        return :stale if transaction.lock_version != @lock_version
        return :invalid if @choices.empty?

        lines = transaction.lines.index_by(&:id)
        return :changed unless @choices.all? { |choice| lines[choice.line_id]&.uncategorised? }

        categories = Category.where(id: @choices.map(&:category_id)).index_by(&:id)
        valid = @choices.all? do |choice|
          category = categories[choice.category_id]
          category&.leaf? && category.slug != Category::UNCATEGORISED_SLUG &&
            TransactionLine::CATEGORY_ORIGINS.include?(choice.origin)
        end
        valid ? nil : :invalid
      end

      def apply(transaction)
        lines = transaction.lines.index_by(&:id)
        @choices.each do |choice|
          taken = choice.origin != "person"
          lines.fetch(choice.line_id).assign_attributes(
            category_id: choice.category_id, category_origin: choice.origin,
            category_origin_probability: (choice.probability if taken),
            category_origin_model_version: (choice.model_version if taken)
          )
        end
        transaction.status = transaction.status_after_categorising
        transaction.save!
      end
  end
end
