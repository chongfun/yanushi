class RetargetPaymentIngestionsToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_reference :payment_ingestions, :receipt, null: true, foreign_key: true
    remove_reference :payment_ingestions, :tenant_payment, foreign_key: true
  end
end
