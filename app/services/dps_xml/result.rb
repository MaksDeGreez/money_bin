module DpsXml
  # What the reader made of one file: the ground-truth `document` (ReceiptGroundTruth::Document), whether the
  # file had item lines at all (`items_known`), the `format` variant that read it, and `notes`: counts of what
  # it left out or met on the way (a value that was not an exact decimal, an item without a name, a surcharge),
  # by kind, never the values themselves.
  Result = Data.define(:document, :items_known, :format, :notes) do
    def return_receipt?
      document["is_return"] == true
    end
  end
end
