# One page of a list read with a KeysetCursor: the rows, and the cursor of the next page (nil on the
# last page).
ResultPage = Data.define(:records, :next_cursor) do
  def last_page?
    next_cursor.nil?
  end
end
