target :app do
  signature "sig/app"
  signature "sig/rbs_rails"
  signature "sig/shims"

  library "date"
  library "bigdecimal"

  check "app/services/leases/save_service.rb"
  check "app/services/leases/scheduled_rent_sync_service.rb"
  check "app/services/service_result.rb"
  check "app/services/service_result_types.rb"
  check "app/services/payment_ingestions/ingestion_result.rb"
  check "app/services/payment_ingestions/parsers/base.rb"
  check "app/services/payment_ingestions/parsers/chase_statement.rb"
  check "app/services/payment_ingestions/parsers/venmo.rb"
  check "app/services/payment_ingestions/parsers/zelle.rb"
end
