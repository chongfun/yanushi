# Shared reading of the filter params the Money list pages accept. Both the
# Receipts and Expenses indexes narrow by property and by year, and both must
# ignore a value they cannot honor (a property belonging to someone else, an
# unparseable year) rather than raising or filtering to nothing.
module IndexFilters
  extend ActiveSupport::Concern

  private

    # The id only when it names one of the given properties, so a foreign or
    # bogus id filters nothing instead of leaking the existence of a record.
    def filter_property_id(properties)
      return nil if params[:property_id].blank?

      properties.find_by(id: params[:property_id])&.id
    end

    def filter_year_range
      return nil if params[:year].blank?

      range = Accounting::DateRange.new(year: params[:year])
      range.valid? ? range : nil
    end
end
