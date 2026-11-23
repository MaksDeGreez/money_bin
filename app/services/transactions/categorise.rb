module Transactions
  # Sets the categories of a transaction's lines, as a person decided on the transactions list (an uncategorised
  # line, one at a time, or "Change" on any line) or by confirming a bulk acceptance (docs/domain.md, "Transaction
  # suggestions").
  #
  #   Transactions::Categorise.call(transaction_id, lock_version: 7, choices: [
  #     Transactions::Categorise::Choice.new(line_id: 12, category_id: 5, origin: "suggestion",
  #       shown_category_id: 5, shown_model_version: "2026-11-18-0123456789ab")
  #   ])  # => Result with status :categorised, :stale, :changed, :on_receipt or :invalid
  #
  #   # "Change": every line of the transaction, each with the category the person saw (nil for none).
  #   Transactions::Categorise.call(transaction_id, lock_version: 7, edit: true, choices: [
  #     Transactions::Categorise::Choice.new(line_id: 12, category_id: 9, origin: "person", observed_category_id: 5)
  #   ])  # => also :unchanged when every chosen category is the one already there
  #
  # The rules:
  # - Without `edit`, only an uncategorised line (no category, or Uncategorised) is ever written: a category a
  #   person (or anything else) chose is never overwritten. A line that has a category by now is :changed and
  #   nothing is written. The bulk acceptance relies on this.
  # - With `edit` (a person's correction, "Change" on the list or the transaction page), a category may be replaced.
  #   Every line of the transaction comes together with the category the person saw on it, and is saved together
  #   with the others or not at all. A line whose category is not the observed one any more is :changed (a line's
  #   category can change without moving the transaction's lock_version, so the version alone is not enough). A
  #   line whose choice is its current category is skipped; when none differs nothing is written and the answer is
  #   :unchanged. Clearing a category (an empty choice, or Uncategorised, for a line that has one) is :invalid; a
  #   line with no category left empty is skipped. Only the person's own choice is accepted (origin `person`, no
  #   suggestion shown; anything else is :invalid): a changed line gets `category_origin` person with no
  #   probability or artefact, and its stored suggestion stays as it is.
  # - `lock_version` is the transaction's version the person saw (the list row, or the bulk preview). The
  #   transaction row and its lines are locked (SELECT ... FOR UPDATE: a suggestion refresh, which writes the
  #   lines, waits) and compared with it; a newer version is :stale and nothing is written, so an edit made
  #   meanwhile always wins.
  # - `shown_category_id` and `shown_model_version` are the suggestion the person saw (nil when none was shown).
  #   A line whose stored suggestion is not that one any more (refreshed by another artefact since) is :changed:
  #   nobody approved the new one. A taken suggestion (`suggestion`, `bulk`) must be the one shown, and its
  #   probability and artefact are recorded from the line, as verified under the lock.
  # - A transfer leg has no lines (:changed). A transaction booked from a receipt is :on_receipt, in both modes:
  #   its lines are rebuilt from the receipt's items on every "Accept again", so a category set here would be
  #   lost; it is categorised on the receipt.
  # - The lines are written through their transaction (nested autosave), so the model's rules run: a line must be
  #   a category (not a group), the sum is untouched, the save bumps lock_version. A save the model refuses
  #   (a row that no longer passes a validation) is :invalid, never an exception.
  # - The status follows Transaction#status_after_categorising: `needs_review` becomes `confirmed` once no line is
  #   uncategorised and no other reason remains; a draft stays a draft.
  #
  # All in one database transaction (a savepoint inside a caller's), so a refusal writes nothing.
  class Categorise
    # `observed_category_id` is read in the edit mode only: the category the person saw on the line (nil: none).
    Choice = Data.define(:line_id, :category_id, :origin, :shown_category_id, :shown_model_version, :observed_category_id) do
      def initialize(line_id:, category_id:, origin:, shown_category_id: nil, shown_model_version: nil, observed_category_id: nil)
        super
      end

      def taken? = origin != "person"
    end
    Result = Data.define(:status, :transaction) do
      def categorised? = status == :categorised
      def unchanged? = status == :unchanged
      # Nothing went wrong: the lines are as the person asked (written now, or already so).
      def saved? = categorised? || unchanged?
    end

    def self.call(transaction_id, lock_version:, choices:, edit: false)
      new(transaction_id, lock_version:, choices:, edit:).call
    end

    def initialize(transaction_id, lock_version:, choices:, edit: false)
      @transaction_id = transaction_id
      @lock_version = Integer(lock_version)
      @choices = Array(choices)
      @edit = edit
    end

    def call
      transaction = nil
      status = Transaction.transaction(requires_new: true) do
        transaction = lock
        outcome = check(transaction)
        next outcome if outcome

        apply(transaction)
      end
      Result.new(status:, transaction:)
    rescue ActiveRecord::StaleObjectError
      Result.new(status: :stale, transaction:)
    rescue ActiveRecord::RecordInvalid
      Result.new(status: :invalid, transaction:)
    end

    private
      # The transaction row, then its lines, under row locks; then read with its lines as they are now.
      def lock
        return nil unless Transaction.lock.find_by(id: @transaction_id)

        TransactionLine.where(transaction_id: @transaction_id).order(:id).lock.load
        Transaction.includes(:receipt, lines: :category).find(@transaction_id)
      end

      def check(transaction)
        return :changed if transaction.nil? || transaction.transfer_leg?
        return :stale if transaction.lock_version != @lock_version
        return :on_receipt if transaction.receipt
        return :invalid if @choices.empty? || !@choices.all? { |choice| TransactionLine::CATEGORY_ORIGINS.include?(choice.origin) }

        @edit ? check_edit(transaction) : check_uncategorised(transaction)
      end

      def check_uncategorised(transaction)
        lines = transaction.lines.index_by(&:id)
        return :changed unless @choices.all? { |choice| (line = lines[choice.line_id]) && line.uncategorised? && shown_still_stored?(choice, line) }
        return :invalid if @choices.any? { |choice| choice.taken? && choice.category_id != choice.shown_category_id }

        categorisable?(@choices.map(&:category_id)) ? nil : :invalid
      end

      # Every line, once, each still with the category the person saw; only the person's own choices; no category
      # cleared; every new category a category (not a group, not Uncategorised).
      def check_edit(transaction)
        return :invalid if @choices.any? { |choice| choice.taken? || choice.shown_category_id || choice.shown_model_version }
        return :invalid if @choices.map(&:line_id).uniq.size != @choices.size

        lines = transaction.lines.index_by(&:id)
        return :changed unless lines.keys.to_set == @choices.to_set(&:line_id)
        return :changed unless @choices.all? { |choice| lines[choice.line_id].category_id == choice.observed_category_id }

        changes = edits(lines)
        return :invalid if changes.any? { |choice| choice.category_id.nil? }

        categorisable?(changes.map(&:category_id)) ? nil : :invalid
      end

      # The choices that differ from the line's category now: a line with no category left empty is not one.
      def edits(lines)
        @choices.reject { |choice| choice.category_id == lines.fetch(choice.line_id).category_id }
      end

      def categorisable?(category_ids)
        categories = Category.where(id: category_ids).index_by(&:id)
        category_ids.all? do |id|
          category = categories[id]
          category&.leaf? && category.slug != Category::UNCATEGORISED_SLUG
        end
      end

      # The suggestion the person saw is the one the line stores now (or none was shown).
      def shown_still_stored?(choice, line)
        return true if choice.shown_category_id.nil? && !choice.taken?

        line.suggested_category_id == choice.shown_category_id && line.suggestion_model_version == choice.shown_model_version
      end

      def apply(transaction)
        lines = transaction.lines.index_by(&:id)
        choices = @edit ? edits(lines) : @choices
        return :unchanged if choices.empty?

        choices.each do |choice|
          line = lines.fetch(choice.line_id)
          line.assign_attributes(
            category_id: choice.category_id, category_origin: choice.origin,
            category_origin_probability: (line.suggestion_probability if choice.taken?),
            category_origin_model_version: (line.suggestion_model_version if choice.taken?)
          )
        end
        transaction.status = transaction.status_after_categorising
        transaction.save!
        :categorised
      end
  end
end
