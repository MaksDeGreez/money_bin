module Receipts
  # A person's check of a receipt's tax-service record (its `dps_xml` ground truth) against the printed receipt
  # in the photos (docs/domain.md, "Checking an imported record").
  #
  #   POST   /receipts/:receipt_id/ground_truth_check   outcome=matches|differs, note (optional)
  #   DELETE /receipts/:receipt_id/ground_truth_check   forgets the check
  #
  # A checked record can be checked again: the new outcome and note replace the old ones. A checked record is
  # never replaced by a later import (GroundTruthImport). Only the record's check columns are written: never
  # its document, the receipt or its items. Both answer with a redirect to the receipt page, its list filter
  # kept; a receipt without a tax-service record, or an outcome that is not one of the two, is refused there.
  class GroundTruthChecksController < ApplicationController
    OUTCOMES = %w[matches differs].freeze

    before_action :set_receipt_and_filter

    def create
      outcome = params[:outcome].to_s
      return back(alert: "Not recorded: choose \"Matches the print\" or \"Differs from the print\".") unless OUTCOMES.include?(outcome)

      record = dps_record
      return back(alert: "This receipt has no tax-service record to check.") unless record

      record.record_check!(matches: outcome == "matches", note: params[:note].to_s.truncate(1000))
      LiveUpdate.changed(@receipt)
      back(notice: outcome == "matches" ? "Recorded: the tax-service record matches the print." :
        "Recorded: the tax-service record differs from the print.")
    end

    def destroy
      record = dps_record
      return back(alert: "This receipt has no tax-service record to check.") unless record

      record.clear_check! if record.checked?
      LiveUpdate.changed(@receipt)
      back(notice: "The check is forgotten.")
    end

    private
      def set_receipt_and_filter
        @receipt = Receipt.find(params[:receipt_id])
        @filter = Receipt::Filter.new(params.slice(*Receipt::Filter::KEYS).permit(*Receipt::Filter::KEYS).to_h)
      end

      def dps_record
        ReceiptGroundTruth.dps_xml.find_by(receipt_id: @receipt.id)
      end

      def back(**flash)
        redirect_to receipt_path(@receipt, @filter.to_params.merge(anchor: "ground-truth")), status: :see_other, **flash
      end
  end
end
