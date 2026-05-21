class AddIndexToPaymentIngestionsOnDuplicateFields < ActiveRecord::Migration[8.1]
  def change
    add_index :payment_ingestions, [ :user_id, :payment_method, :transaction_number ],
              name: "idx_payment_ingestions_dup_check"
  end
end
