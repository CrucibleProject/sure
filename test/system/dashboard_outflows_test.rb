require "application_system_test_case"

class DashboardOutflowsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @shopping = @user.family.categories.create!(name: "Shopping", color: "#3b82f6")
    @amazon = @user.family.categories.create!(name: "Amazon", parent: @shopping)
    account = @user.family.accounts.first
    create_transaction(account: account, amount: 100, category: @shopping)
    create_transaction(account: account, amount: 50, category: @amazon)
    sign_in @user
  end

  test "outflow breakdown and links work from the keyboard without grabbing the card" do
    section = find("section[data-section-key='outflows_donut']")
    summary = find("details[data-outflow-category-id='#{@shopping.id}'] summary")
    retailer = "a[data-outflow-subcategory-id='#{@amazon.id}']"

    assert_selector retailer
    summary.send_keys(:enter)
    assert_no_selector retailer
    assert_equal "false", section["aria-grabbed"]

    summary.send_keys(:space)
    assert_selector retailer
    assert_equal "false", section["aria-grabbed"]

    find(retailer).send_keys(:enter)
    assert_current_path transactions_path, ignore_query: true
    filters = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query).fetch("q")
    assert_equal [ "Amazon" ], filters.fetch("categories")
    assert_equal [ "confirmed" ], filters.fetch("status")
  end

  test "dashboard cards and their drag handles still support keyboard reordering" do
    section = find("section[data-section-key='outflows_donut']")
    section.send_keys(:enter)
    assert_selector "section[data-section-key='outflows_donut'][aria-grabbed='true']"
    section.send_keys(:escape)
    assert_selector "section[data-section-key='outflows_donut'][aria-grabbed='false']"

    # Tab past the collapse button to the drag handle, which fades in on hover.
    section.send_keys(:tab, :tab, :space)
    assert_equal "handle", page.evaluate_script("document.activeElement.dataset.dashboardSortableTarget")
    assert_selector "section[data-section-key='outflows_donut'][aria-grabbed='true']"
    section.send_keys(:escape)
    assert_selector "section[data-section-key='outflows_donut'][aria-grabbed='false']"
  end
end
