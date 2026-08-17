class ProvisionMilestone5ExpenseAccounts < ActiveRecord::Migration[8.1]
  def up
    User.find_each do |user|
      Accounting::ChartOfAccounts.ensure_for(user)
    end
  end

  def down
    # Account removal is intentionally not supported;
    # ensure_for is idempotent and safe to re-run.
  end
end
