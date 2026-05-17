require "test_helper"

class TenantTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:one)
  end

  test "has_many tenant_aliases association" do
    assert_respond_to @tenant, :tenant_aliases
  end

  test "all_names returns normalized primary name and alias names" do
    @tenant.update!(name: "Kristina M Page")
    @tenant.tenant_aliases.create!(name: "Katie Page")
    @tenant.tenant_aliases.create!(name: "KRISTINA M PAGE ALIAS")

    expected_names = [ "kristina m page", "katie page", "kristina m page alias" ]
    assert_equal expected_names.sort, @tenant.all_names.sort
  end
end
