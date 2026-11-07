require "test_helper"
require "ostruct"

class PlaidItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @mock_provider = mock("Provider::Plaid")
    @plaid_item = plaid_items(:one)
    @importer = PlaidItem::Importer.new(@plaid_item, plaid_provider: @mock_provider)
  end

  test "imports item metadata" do
    item_data = OpenStruct.new(
      item_id: "item_1",
      available_products: [ "transactions", "investments", "liabilities" ],
      billed_products: [],
      institution_id: "ins_1",
      institution_name: "First Platypus Bank",
    )

    @mock_provider.expects(:get_item).with(@plaid_item.access_token).returns(
      OpenStruct.new(item: item_data)
    )

    institution_data = OpenStruct.new(
      institution_id: "ins_1",
      institution_name: "First Platypus Bank",
    )

    @mock_provider.expects(:get_institution).with("ins_1").returns(
      OpenStruct.new(institution: institution_data)
    )

    PlaidItem::AccountsSnapshot.any_instance.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "acc_1",
        type: "depository",
      )
    ]).at_least_once

    PlaidItem::AccountsSnapshot.any_instance.expects(:transactions_cursor).returns("test_cursor_1")

    PlaidItem::AccountsSnapshot.any_instance.expects(:get_account_data).with("acc_1").once

    PlaidAccount::Importer.any_instance.expects(:import).once

    @plaid_item.expects(:update!).with(next_cursor: "test_cursor_1")
    @plaid_item.expects(:upsert_plaid_snapshot!).with(item_data)
    @plaid_item.expects(:upsert_plaid_institution_snapshot!).with(institution_data)

    @importer.import
  end

  test "login errors cannot be reported as successful imports" do
    error = Plaid::ApiError.new(response_body: { error_code: "ITEM_LOGIN_REQUIRED" }.to_json)
    @mock_provider.expects(:get_item).raises(error)

    assert_raises(Plaid::ApiError) { @importer.import }
    assert @plaid_item.reload.requires_update?
  end

  test "successful import clears an obsolete reconnect warning" do
    @plaid_item.requires_update!
    @importer.stubs(:fetch_and_import_item_data)
    @importer.stubs(:fetch_and_import_accounts_data)

    @importer.import

    assert @plaid_item.reload.good?
  end
end
