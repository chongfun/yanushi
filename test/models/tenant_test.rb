require "test_helper"

class TenantTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:one)
    @tenant.update!(name: "Jane Doe")
  end

  test "alias_candidate? returns false for blank values" do
    assert_not @tenant.alias_candidate?(nil)
    assert_not @tenant.alias_candidate?("")
    assert_not @tenant.alias_candidate?("   ")
  end

  test "alias_candidate? returns false if it matches tenant name case-insensitively" do
    assert_not @tenant.alias_candidate?("Jane Doe")
    assert_not @tenant.alias_candidate?("jane doe")
    assert_not @tenant.alias_candidate?("  JANE DOE  ")
  end

  test "alias_candidate? returns false if alias already exists" do
    @tenant.tenant_aliases.create!(alias_name: "J. Doe")
    assert_not @tenant.alias_candidate?("J. Doe")
    assert_not @tenant.alias_candidate?("j. doe")
    assert_not @tenant.alias_candidate?("  J. DOE  ")
  end

  test "alias_candidate? returns true for new unique aliases" do
    assert @tenant.alias_candidate?("Janey")
    assert @tenant.alias_candidate?("Jane D.")
  end

  test "alias_candidate? uses in-memory check if tenant_aliases association is loaded" do
    @tenant.tenant_aliases.create!(alias_name: "J. Doe")

    # Preload the association
    @tenant.tenant_aliases.load

    assert_no_queries do
      assert_not @tenant.alias_candidate?("J. Doe")
      assert @tenant.alias_candidate?("Jane D.")
    end
  end
end
