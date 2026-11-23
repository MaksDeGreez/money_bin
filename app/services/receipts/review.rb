module Receipts
  # Stores a person's corrections from the review form, with `intent: "accept"` books the receipt, and with
  # `intent: "ground_truth"` saves it as the receipt's manual ground truth (docs/domain.md, "Review" and
  # "Manual ground truth").
  #
  #   review = Receipts::Review.new(receipt, form_params, intent: "save")
  #   review.call        # => true, or false with errors on review.form_receipt and its items
  #   review.transaction # the booked transaction after an accept
  #   review.ground_truth # the Receipts::SaveGroundTruth result after "Save as ground truth"
  #
  # `form_params` are the form's fields: the header (kind, merchant_name, issued_at, total, currency,
  # fiscal_number, receipt_number, card_last4, incomplete, category_id), `items_attributes` (id, name,
  # quantity, unit_price, discount, amount, category_id, _destroy), `lock_version` (the receipt's version the
  # page was rendered from), `transaction_lock_version` (for a reviewed receipt, its transaction's), and
  # `account_id` and `remove_items` (the confirmation that turning a receipt with items into a card slip
  # removes them), `filled_from` ("dps_xml" when the person filled the form from the tax-service record),
  # `without_categories` and `replace_ground_truth` (for "Save as ground truth"), and the "Book as" choice:
  # `booking` ("new", or the id of the chosen ledger transaction), `link_lock_versions` (each candidate's
  # `lock_version` as shown, by id), `shown_candidate_ids`, `shown_linked_ids` and `shown_exact_ids` (the ids the
  # page listed, separated by spaces; the last: the candidates whose amount was the booking total).
  #
  # Rules:
  # - Only a receipt a person may review is saved: `extracted` or `reviewed`, with no OCR queued or running
  #   (Receipt#reviewable?). A `reviewed` one is booked: it changes only through "Accept again", which saves
  #   and books in one go, never by a plain save that would leave items and lines apart.
  # - Stale forms are refused: the receipt's `lock_version` (and, for a reviewed receipt, its transaction's)
  #   must be the one the page was rendered from. OCR read again, or another tab saved, means "changed
  #   somewhere else", and nothing is written.
  # - Money and quantities go through MoneyInput (a comma is a decimal separator) and reach the models as
  #   text, so more places than the column keeps is an error and nothing is rounded.
  # - The corrections overwrite the receipt's columns and items. `ocr_raw`, `ocr_model_*`, the QR ground truth
  #   (`qr_*`, `qr_payload`), `ingest_id`, `batch`, the photos and `status` are not form fields and are never
  #   written here (an accept moves the status through Receipts::Accept).
  # - An item whose category a person set or changed gets `accepted_by_user`; a new row gets a position after
  #   every item and every OCR item, so position N still names item N of `ocr_raw`. Blank new rows are left out.
  # - A card slip has no items: a receipt with items becomes a slip only with `remove_items`, and then they are
  #   removed by this save. Only a slip keeps a category of its own; other kinds have it cleared.
  # - The save always writes the receipt row, so its `lock_version` moves and an older form is refused.
  # - "Accept" saves and then runs Receipts::Accept, in one database transaction: a refusal (TotalMismatch,
  #   no account, ...) leaves nothing saved, and the typed values stay on the form with the reason.
  # - "Accept" on a receipt without a ledger transaction books it as the person chose under "Book as": onto a
  #   ledger transaction of the list (ReceiptLinkCandidates), with the `lock_version` the page showed and no
  #   account, or as a new expense on the chosen account. The list is computed again from the values just
  #   saved, in the same database transaction; when its ids are not the ones the page showed (the date or the
  #   total was corrected, a bank row arrived, another receipt took one), or which of them match the items' sum
  #   exactly changed, or no choice was made, nothing is booked or saved and the fresh list goes back to the form
  #   (`link_candidates`) with nothing chosen. So a "new expense" chosen before a correction cannot go through
  #   past a match the person has not seen. A refusal about the chosen transaction (changed, gone, taken) also
  #   returns the list as it is then. A lock that could not be had (a deadlock with an import) is a message too.
  # - "Save as ground truth" saves as "Save" does and then writes the manual ground-truth record from the
  #   stored receipt (Receipts::SaveGroundTruth), in one database transaction; it never books and never moves
  #   the status. Before it, the form must be complete enough to be ground truth (the kind set, a total and
  #   a date unless the receipt is marked incomplete, a fiscal receipt's items, and every category unless
  #   "Save without categories" is ticked): each gap is an error on its field. Replacing a record that exists
  #   needs a confirmation (the first attempt rolls back and returns the differences). On a `reviewed`
  #   receipt nothing may change (that is "Accept again"): the stored receipt is saved as ground truth as it is.
  # - `filled_from` is written only as "dps_xml", only when the receipt has a tax-service record; a later
  #   save leaves it as it is (the values still come from that fill), and a new OCR result clears it.
  #
  # After a failure `form_receipt` holds what the person typed, with the errors, to render the form again:
  # the receipt itself when the values could be assigned, or a detached copy when the receipt changed under
  # the form (conflict) or may not be edited now (OCR running), so the typed values are never lost.
  class Review
    HEADER_FIELDS = %i[kind merchant_name issued_at total currency fiscal_number receipt_number card_last4 incomplete category_id].freeze
    ITEM_FIELDS = %i[id name quantity unit_price discount amount category_id _destroy].freeze
    MONEY_ITEM_FIELDS = %i[unit_price discount amount].freeze
    NUMERIC_ITEM_FIELDS = (MONEY_ITEM_FIELDS + %i[quantity]).freeze
    INTENTS = %w[save accept ground_truth].freeze
    ISSUED_AT_FORMAT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?\z/
    CONFLICT = "This receipt changed somewhere else after this page was opened (OCR read it again, or it was saved " \
      "in another tab). Nothing was saved. Your values are still on this page: open the current version, check it, " \
      "and enter your changes there.".freeze

    BOOKED_UNCHANGED = "This receipt is booked, so it changes only through \"Accept again\". Accept it again first, " \
      "then save it as ground truth. Nothing was saved.".freeze
    CATEGORIES_NEEDED = "Every item needs a category to be saved as ground truth (a card slip needs its own), or tick " \
      "\"Save without categories\".".freeze
    CANDIDATES_CHANGED = "Not accepted: the ledger transactions that match this receipt changed (your corrections, or a " \
      "change in the ledger). Nothing was saved. Check the list under \"Book as\" and choose again.".freeze
    LOCK_FAILED = "Not accepted: the transaction was being written by something else at the same moment (an import?). " \
      "Nothing was saved. Try again.".freeze
    CHOICE_NEEDED = "Not accepted: choose under \"Book as\" whether this receipt books onto a transaction already in the " \
      "ledger or as a new expense. Nothing was saved.".freeze
    NEW_BOOKING = "new".freeze

    # The "Book as" choice cannot go through; the message goes next to it.
    class BookingRefused < StandardError; end

    attr_reader :receipt, :form_receipt, :transaction, :version, :transaction_version, :account, :ground_truth,
      :link_candidates

    def self.permitted_params
      [ *HEADER_FIELDS, :lock_version, :transaction_lock_version, :account_id, :remove_items, :filled_from,
        :without_categories, :replace_ground_truth, :booking, :shown_candidate_ids, :shown_linked_ids, :shown_exact_ids,
        { items_attributes: ITEM_FIELDS, link_lock_versions: {} } ]
    end

    def initialize(receipt, params, intent: "save")
      @receipt = receipt
      @params = params.to_h.with_indifferent_access
      @intent = INTENTS.include?(intent.to_s) ? intent.to_s : "save"
      @version = @params[:lock_version].to_s
      @transaction_version = @params[:transaction_lock_version].to_s
      @account = Account.active.find_by(id: @params[:account_id]) if @params[:account_id].present?
      @form_receipt = receipt
    end

    def accept?
      @intent == "accept"
    end

    def ground_truth?
      @intent == "ground_truth"
    end

    # "Save as ground truth" stopped to ask before replacing the record that exists (ground_truth holds the
    # differences and the token); nothing was saved.
    def confirmation_needed?
      @ground_truth&.confirm? == true
    end

    def without_categories?
      ActiveModel::Type::Boolean.new.cast(@params[:without_categories]) == true
    end

    # True when this save turned the receipt into a card slip (it then wants a slip suggestion).
    def became_slip?
      @became_slip == true
    end

    # True when the receipt changed under the form.
    def conflict?
      @conflict == true
    end

    # The "Book as" choice sent ("new", a transaction id, or nil), to keep it chosen on a refused form; nil after
    # the list changed, since then the person must choose again.
    def booking
      @params[:booking].to_s.presence unless candidates_changed? || @choose_again
    end

    # True when an accept found other matching transactions than the form listed.
    def candidates_changed?
      @candidates_changed == true
    end

    def call
      # Its own savepoint inside a caller's transaction, so a refusal rolls the save back there too.
      saved = Receipt.transaction(requires_new: true) do
        @receipt.lock!
        next refuse_detached(not_editable_message) if not_editable_message
        next refuse_detached(CONFLICT, conflict: true) if stale?

        kind_before = @receipt.kind
        assign
        next false unless valid?
        next refuse(BOOKED_UNCHANGED) if ground_truth? && @receipt.reviewed? && form_changes?

        unless ground_truth? && @receipt.reviewed?
          @receipt.updated_at = Time.current
          @removed_items = @receipt.items.select(&:marked_for_destruction?)
          @receipt.save!
        end
        @became_slip = kind_before != "card_slip" && @receipt.card_slip? && !accept?
        @transaction = book if accept?
        if ground_truth?
          @ground_truth = SaveGroundTruth.call(Receipt.includes(:category, items: :category).find(@receipt.id),
            confirm: @params[:replace_ground_truth])
          raise ActiveRecord::Rollback if @ground_truth.confirm?
        end
        true
      rescue Accept::Error => error
        accept_refused(error)
        raise ActiveRecord::Rollback
      rescue BookingRefused => error
        @transaction = nil
        @receipt.errors.add(:booking, error.message)
        raise ActiveRecord::Rollback
      rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
        # PostgreSQL aborted the transaction: nothing more can be read in it. The page reads the list again.
        @transaction = nil
        @link_candidates = nil
        @receipt.errors.add(:base, LOCK_FAILED)
        raise ActiveRecord::Rollback
      rescue ActiveRecord::RecordInvalid => error
        # A booking the models refuse (the items sum past the amount limit, say): a reason on the form, not a 500.
        @ground_truth = nil
        prefix = ground_truth? ? "Not saved as ground truth" : "Not accepted"
        @receipt.errors.add(:base, "#{prefix}: #{error.record.errors.full_messages.to_sentence}.")
        raise ActiveRecord::Rollback
      rescue ActiveRecord::StaleObjectError
        refuse_detached(CONFLICT, conflict: true)
        raise ActiveRecord::Rollback
      end
      unless saved
        restore_removed_items
        return false
      end

      @version = Receipt.where(id: @receipt.id).pick(:lock_version).to_s
      LiveUpdate.changed(@receipt)
      true
    end

    private
      # Books the receipt as just saved: "Accept again" onto its own transaction; otherwise as the person chose
      # under "Book as", once the list of matching transactions is still the one the page showed.
      def book
        stored = Receipt.find(@receipt.id)
        return Accept.call(stored) if stored.transaction_id

        @link_candidates = ReceiptLinkCandidates.new(stored)
        unless same_ids?(@params[:shown_candidate_ids], @link_candidates.candidate_ids) &&
            same_ids?(@params[:shown_linked_ids], @link_candidates.linked_ids) &&
            same_ids?(@params[:shown_exact_ids], @link_candidates.exact_ids)
          @candidates_changed = true
          raise BookingRefused, CANDIDATES_CHANGED
        end

        choice = @params[:booking].to_s
        if choice == NEW_BOOKING
          Accept.call(stored, account: @account)
        elsif (chosen = @link_candidates.candidates.find { |candidate| candidate.id.to_s == choice })
          @linking = true
          versions = @params[:link_lock_versions]
          version = versions[choice] if versions.is_a?(Hash)
          Accept.call(stored, link: chosen.id, link_lock_version: version)
        else
          raise BookingRefused, CHOICE_NEEDED
        end
      end

      # The ids a hidden field listed ("12 40 7") are these ids, in any order.
      def same_ids?(shown, ids)
        shown.to_s.split.sort == ids.map(&:to_s).sort
      end

      # The save destroyed the rows marked for removal and dropped them from the items in memory; the rollback
      # brought them back in the database only. They go back on the form, still marked, so the page shows
      # them as removed (hidden, _destroy=1) and the next save removes them again instead of keeping them.
      def restore_removed_items
        return if @removed_items.blank? || @form_receipt != @receipt

        target = @receipt.association(:items).target
        missing = @removed_items.reject { |item| target.include?(item) }
        missing.each(&:mark_for_destruction)
        @receipt.association(:items).target = (target + missing).sort_by { |item| item.position || Float::INFINITY }
      end

      def stale?
        return true if @version != @receipt.lock_version.to_s
        return false unless @receipt.transaction_id

        current = Transaction.where(id: @receipt.transaction_id).lock.pick(:lock_version).to_s
        @transaction_version != current
      end

      def refuse(message)
        @receipt.errors.add(:base, message)
        false
      end

      # Whether the form changes anything stored: a header field, an item, a row added or removed. An empty
      # text field the form sends ("") for a stored nil is no change.
      def form_changes?
        changed = ->(record) { record.changes.any? { |_, (old, new)| blank_as_nil(old) != blank_as_nil(new) } }
        changed.(@receipt) || @receipt.items.any? { |item| item.new_record? || item.marked_for_destruction? || changed.(item) }
      end

      def blank_as_nil(value)
        value.is_a?(String) ? value.strip.presence : value
      end

      def not_editable_message
        if @receipt.ocr_in_flight?
          "Not saved: OCR is reading this receipt again, and its result will replace these fields and items. " \
            "Your values are still on this page."
        elsif !Receipt::REVIEWABLE_STATUSES.include?(@receipt.status)
          "Not saved: a receipt that is #{@receipt.status} cannot be reviewed."
        elsif @receipt.reviewed? && !accept? && !ground_truth?
          "An accepted receipt changes only through \"Accept again\", which books the change too."
        end
      end

      # --- Assigning the form's values ------------------------------------------------------------------

      def assign(target = @receipt, detached: false)
        @money_errors = []
        target.assign_attributes(header_attributes)
        assign_items(target, detached:)
        assign_slip(target) unless detached
        assign_filled_from(target)
      end

      # Only the one value, and only when there is a record to have filled the form from.
      def assign_filled_from(target)
        return unless @params[:filled_from].to_s == "dps_xml"
        return unless ReceiptGroundTruth.dps_xml.exists?(receipt_id: @receipt.id)

        target.filled_from = "dps_xml"
      end

      def header_attributes
        attributes = @params.slice(*HEADER_FIELDS).to_h.symbolize_keys
        attributes[:total] = money(:total, attributes[:total]) if attributes.key?(:total)
        attributes[:category_id] = attributes[:category_id].presence if attributes.key?(:category_id)
        attributes[:kind] = attributes[:kind].presence if attributes.key?(:kind)
        attributes[:card_last4] = attributes[:card_last4].to_s.strip.presence if attributes.key?(:card_last4)
        attributes[:issued_at] = issued_at(attributes[:issued_at]) if attributes.key?(:issued_at)
        attributes
      end

      def issued_at(text)
        text = text.to_s.strip
        return nil if text.empty?

        time = Time.zone.parse(text) if text.match?(ISSUED_AT_FORMAT)
        time || begin
          @money_errors << [ nil, :issued_at, "must be a date and time" ]
          text
        end
      rescue ArgumentError
        @money_errors << [ nil, :issued_at, "must be a date and time" ]
        text
      end

      def money(field, text, item_key: nil)
        normalized = MoneyInput.normalize(text)
        if normalized.nil?
          @money_errors << [ item_key, field, MoneyInput::MESSAGE ]
          text
        else
          normalized.presence
        end
      end

      def item_rows
        rows = @params[:items_attributes]
        rows = rows.values if rows.is_a?(Hash)
        Array(rows).map { |row| row.to_h.with_indifferent_access }
      end

      def assign_items(target, detached:)
        position = next_position
        rows = item_rows.filter_map.with_index do |row, index|
          attributes = row.slice(*ITEM_FIELDS).to_h.symbolize_keys
          next if attributes[:id].blank? && blank_row?(attributes)

          NUMERIC_ITEM_FIELDS.each do |field|
            next unless attributes.key?(field)

            attributes[field] = money(field, attributes[field], item_key: index)
          end
          attributes[:discount] ||= "0" if attributes.key?(:discount)
          attributes[:category_id] = attributes[:category_id].presence if attributes.key?(:category_id)
          if attributes[:id].blank?
            attributes.delete(:id)
            attributes[:position] = (position += 1)
          end
          [ index, attributes ]
        end

        @row_items = {}
        if detached
          stored = @receipt.items.index_by { |item| item.id.to_s }
          target.association(:items).target = rows.map do |index, attributes|
            destroy = ActiveModel::Type::Boolean.new.cast(attributes.delete(:_destroy))
            # The suggestion of a stored item is not a form field: it comes from the item, so "Use" stays.
            if (item = stored[attributes[:id].to_s])
              attributes = item.slice(:suggested_category_id, :confidence, :suggested_by, :accepted_by_user).symbolize_keys.merge(attributes)
            end
            ReceiptItem.new(attributes).tap do |item|
              item.mark_for_destruction if destroy
              @row_items[index] = item
            end
          end
        else
          target.items_attributes = rows.map(&:last)
          map_rows_to_items(target, rows)
          mark_categories_chosen(target)
        end
      end

      def blank_row?(attributes)
        attributes.except(:_destroy, :discount).values.all?(&:blank?) && attributes[:discount].to_s.strip.in?([ "", "0" ])
      end

      # Nested attributes keep the order of the rows: existing items by id, new ones appended in order.
      def map_rows_to_items(target, rows)
        new_items = target.items.select(&:new_record?)
        rows.each do |index, attributes|
          @row_items[index] = attributes[:id] ? target.items.find { |item| item.id.to_s == attributes[:id].to_s } : new_items.shift
        end
      end

      def mark_categories_chosen(target)
        target.items.each do |item|
          next unless item.new_record? || item.will_save_change_to_category_id?

          item.accepted_by_user = item.category_id.present?
        end
      end

      # After every stored item and every item of the OCR answer, so position N keeps naming item N of ocr_raw.
      def next_position
        stored = @receipt.items.map(&:position).compact.max || 0
        answer = @receipt.ocr_raw.is_a?(Hash) ? Array(@receipt.ocr_raw.dig("receipt", "items")).size : 0
        [ stored, answer ].max
      end

      def assign_slip(target)
        if target.card_slip?
          target.items.each(&:mark_for_destruction) if remove_items?
        else
          target.category_id = nil
        end
      end

      def remove_items?
        ActiveModel::Type::Boolean.new.cast(@params[:remove_items]) == true
      end

      # --- Validation -------------------------------------------------------------------------------------

      def valid?
        @receipt.valid?
        # Autosave validates only items that changed, and "60.004" casts to a stored 60.00 as no change at all:
        # every kept item is validated on its own, so a refused value is never passed over (or rounded).
        @receipt.items.each { |item| item.valid? unless item.marked_for_destruction? }
        @money_errors.each do |item_key, field, message|
          record = item_key.nil? ? @receipt : @row_items[item_key]
          record&.errors&.delete(field)
          record&.errors&.add(field, message)
        end
        if @receipt.card_slip? && @receipt.kept_items.any?
          @receipt.errors.add(:kind, "is a card slip, which has no items: confirm removing the " \
            "#{@receipt.kept_items.size} item(s) below, or keep it a fiscal receipt")
        end
        ground_truth_gaps if ground_truth?
        @receipt.errors.empty? && @receipt.items.all? { |item| item.marked_for_destruction? || item.errors.empty? }
      end

      # What ground truth needs beyond a valid receipt, each gap on its own field. The sum of the items is not
      # checked against the total: a receipt can print a rounding line.
      def ground_truth_gaps
        receipt = @receipt
        receipt.errors.add(:kind, "must be set to save as ground truth") if receipt.kind.nil? && receipt.errors[:kind].empty?
        unless receipt.incomplete?
          { total: "a total", issued_at: "a date and time" }.each do |field, what|
            next if receipt.public_send(field).present? || receipt.errors[field].any?

            receipt.errors.add(field, "is needed to save as ground truth (#{what} is printed on a whole receipt; " \
              "tick \"Incomplete\" if it is torn or cut off)")
          end
        end
        items = receipt.kept_items
        if receipt.fiscal? && items.empty?
          receipt.errors.add(:base, "A fiscal receipt needs its items to be saved as ground truth.")
        end
        return if without_categories?

        missing = items.select { |item| item.category_id.nil? }
        missing.each { |item| item.errors.add(:category_id, "must be chosen to save as ground truth") }
        slip_missing = receipt.card_slip? && receipt.category_id.nil?
        receipt.errors.add(:category_id, "must be chosen to save as ground truth") if slip_missing
        receipt.errors.add(:base, CATEGORIES_NEEDED) if missing.any? || slip_missing
      end

      # --- Refusals ---------------------------------------------------------------------------------------

      # The receipt is not touched: the typed values go onto a detached copy, rendered with the reason.
      def refuse_detached(message, conflict: false)
        @conflict = conflict
        copy = Receipt.new(@receipt.attributes.except("id", "lock_version"))
        copy.readonly!
        assign(copy, detached: true)
        copy.errors.add(:base, message)
        @money_errors.each do |item_key, field, error_message|
          record = item_key.nil? ? copy : @row_items[item_key]
          record&.errors&.add(field, error_message)
        end
        @form_receipt = copy
        false
      end

      # A refusal about the chosen ledger transaction goes next to "Book as", one about the account next to the
      # account select; the others above the form.
      def accept_refused(error)
        @transaction = nil
        # The chosen transaction is not what the person saw any more: they choose again from the list as it is now
        # (read after Accept's savepoint rolled back, past the row lock it waited on).
        @choose_again = [ Accept::TransactionChanged, Accept::LinkGone, Accept::AlreadyLinked, Accept::NotLinkable ].any? { |type| error.is_a?(type) }
        @link_candidates = ReceiptLinkCandidates.new(Receipt.find(@receipt.id)) if @choose_again
        field = if @linking then :booking
        elsif error.is_a?(Accept::CurrencyMismatch) && @receipt.transaction_id then :currency
        elsif error.is_a?(Accept::AccountRequired) || error.is_a?(Accept::CurrencyMismatch) then :account_id
        else :base
        end
        @receipt.errors.add(field, "Not accepted: #{accept_message(error)}")
      end

      def accept_message(error)
        case error
        when Accept::AccountRequired then "choose the account to book it on."
        when Accept::TotalMismatch
          if @linking
            return "#{error.message}. Accepting replaces the chosen transaction's lines with the items, so the two " \
              "must agree: correct the items, or book it as a new expense if it is another purchase."
          end
          "#{error.message}. Accepting again replaces the booked transaction's lines, so the two must agree: correct " \
            "the items (a booked amount cannot be changed in the app yet)."
        when Accept::TransactionChanged
          "#{error.message}. Its lines as they are now are shown below: check them and choose again."
        else "#{error.message}."
        end
      end
  end
end
