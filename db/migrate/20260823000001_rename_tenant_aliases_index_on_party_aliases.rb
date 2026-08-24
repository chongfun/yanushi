class RenameTenantAliasesIndexOnPartyAliases < ActiveRecord::Migration[8.1]
  def change
    rename_index(
      :party_aliases,
      "index_tenant_aliases_on_tenant_id_and_lower_alias_name",
      "index_party_aliases_on_party_id_and_lower_alias_name"
    )
  end
end
