# One page of an ordered relation, with what a page footer needs. No gem: a list here has a few thousand
# rows at most, so a COUNT and an OFFSET are fast enough.
#
#   pagination = Pagination.new(Receipt.newest_first, page: params[:page])
#   pagination.records     # the rows of this page
#   pagination.next_page   # nil on the last page
#
# A page number out of range (0, -1, 999, text) shows the nearest page instead of failing.
class Pagination
  PER_PAGE = 50

  attr_reader :page, :per_page, :total_count, :pages

  def initialize(relation, page:, per_page: PER_PAGE)
    @relation = relation
    @per_page = per_page
    @total_count = relation.unscope(:order, :select).count
    @pages = [ (total_count + per_page - 1) / per_page, 1 ].max
    # Anything but a plain number (page[]=1 arrives as an Array) is page 1.
    @page = (Integer(page.to_s, 10, exception: false) || 1).clamp(1, pages)
  end

  def records
    @relation.offset((page - 1) * per_page).limit(per_page)
  end

  def previous_page
    page - 1 if page > 1
  end

  def next_page
    page + 1 if page < pages
  end

  # The 1-based numbers of the first and last row on this page (0 and 0 when there are none).
  def first_item
    total_count.zero? ? 0 : ((page - 1) * per_page) + 1
  end

  def last_item
    [ page * per_page, total_count ].min
  end
end
