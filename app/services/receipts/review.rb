module Receipts
  # Stores a person's corrections from the review form, and with `intent: "accept"` books the receipt
  # (docs/domain.md, "Review").
  #
  #   review = Receipts::Review.new(receipt, form_params, intent: "save")
  #   review.call        # => true, or false with errors on review.form_receipt and its items
  #   review.transaction # the booked transaction after an accept
  #
  # `form_params` are the form's fields: the header (kind, merchant_name, issued_at, total, currency,
  # fiscal_number, receipt_number, card_last4, incomplete, category_id), `items_attributes` (id, name,
  # quantity, unit_price, discount, amount, category_id, _destroy), `lock_version` (the receipt's version the
  # page was rendered from), `transaction_lock_version` (for a reviewed receipt, its transaction's), and
  # `account_id` and `remove_items` (the confirmation that turning a receipt with items into a card slip
  # removes them).
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
  #
  # After a failure `form_receipt` holds what the person typed, with the errors, to render the form again:
  # the receipt itself when the values could be assigned, or a detached copy when the receipt changed under
  # the form (conflict) or may not be edited now (OCR running), so the typed values are never lost.
  class Review
    HEADER_FIELDS = %i[kind merchant_name issued_at total currency fiscal_number receipt_number card_last4 incomplete category_id].freeze
    ITEM_FIELDS = %i[id name quantity unit_price discount amount category_id _destroy].freeze
    MONEY_ITEM_FIELDS = %i[unit_price discount amount].freeze
    NUMERIC_ITEM_FIELDS = (MONEY_ITEM_FIELDS + %i[quantity]).freeze
    INTENTS = %w[save accept].freeze
    ISSUED_AT_FORMAT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?\z/
    CONFLICT = "This receipt changed somewhere else after this page was opened (OCR read it again, or it was saved " \
      "in another tab). Nothing was saved. Your values are still on this page: open the current version, check it, " \
      "and enter your changes there.".freeze

    attr_reader :receipt, :form_receipt, :transaction, :version, :transaction_version, :account

    def self.permitted_params
      [ *HEADER_FIELDS, :lock_version, :transaction_lock_version, :account_id, :remove_items,
        { items_attributes: ITEM_FIELDS } ]
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

    # True when the receipt changed under the form.
    def conflict?
      @conflict == true
    end

    def call
      saved = Receipt.transaction do
        @receipt.lock!
        next refuse_detached(CONFLICT, conflict: true) if stale?
        next refuse_detached(not_editable_message) if not_editable_message

        assign
        next false unless valid?

        @receipt.updated_at = Time.current
        @receipt.save!
        @transaction = Accept.call(Receipt.find(@receipt.id), account: @account) if accept?
        true
      rescue Accept::Error => error
        accept_refused(error)
        raise ActiveRecord::Rollback
      rescue ActiveRecord::StaleObjectError
        refuse_detached(CONFLICT, conflict: true)
        raise ActiveRecord::Rollback
      end
      return false unless saved

      @version = Receipt.where(id: @receipt.id).pick(:lock_version).to_s
      true
    end

    private
      def stale?
        return true if @version != @receipt.lock_version.to_s
        return false unless @receipt.transaction_id

        current = Transaction.where(id: @receipt.transaction_id).lock.pick(:lock_version).to_s
        @transaction_version != current
      end

      def not_editable_message
        if @receipt.ocr_in_flight?
          "Not saved: OCR is reading this receipt again, and its result will replace these fields and items. " \
            "Your values are still on this page."
        elsif !Receipt::REVIEWABLE_STATUSES.include?(@receipt.status)
          "Not saved: a receipt that is #{@receipt.status} cannot be reviewed."
        elsif @receipt.reviewed? && !accept?
          "An accepted receipt changes only through \"Accept again\", which books the change too."
        end
      end

      # --- Assigning the form's values ------------------------------------------------------------------

      def assign(target = @receipt, detached: false)
        @money_errors = []
        target.assign_attributes(header_attributes)
        assign_items(target, detached:)
        assign_slip(target) unless detached
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
          target.association(:items).target = rows.map do |index, attributes|
            destroy = ActiveModel::Type::Boolean.new.cast(attributes.delete(:_destroy))
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
        @receipt.errors.empty? && @receipt.items.all? { |item| item.marked_for_destruction? || item.errors.empty? }
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

      # The account errors go next to the account select; the others above the form.
      def accept_refused(error)
        @transaction = nil
        field = error.is_a?(Accept::AccountRequired) || error.is_a?(Accept::CurrencyMismatch) ? :account_id : :base
        @receipt.errors.add(field, "Not accepted: #{accept_message(error)}")
      end

      def accept_message(error)
        case error
        when Accept::AccountRequired then "choose the account to book it on."
        when Accept::TotalMismatch
          "#{error.message}. Accepting again replaces the booked transaction's lines, so the two must agree: correct " \
            "the items (a booked amount cannot be changed in the app yet)."
        else "#{error.message}."
        end
      end
  end
end
