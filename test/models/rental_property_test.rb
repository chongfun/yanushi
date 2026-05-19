require "test_helper"

class RentalPropertyTest < ActiveSupport::TestCase
  test "active_years returns years with data and defaults" do
    property = rental_properties(:one)

    # It should include current year even if there's no data for it
    assert_includes property.active_years, Date.current.year

    # It should include years from associated data
    # The fixtures set dates to 2026-04-28
    assert_includes property.active_years, 2026

    # Test with custom additional years
    assert_includes property.active_years([ 2020 ]), 2020
  end
end
