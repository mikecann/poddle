Feature: Up Next
  As a listener
  I want to arrange my queue by hand
  So I hear things in the order I want, and can take back a slip

  Background:
    Given the listener follows "Morning Tones" with "Sunrise in A", "Breakfast in C" and "Commute in D" in Up Next
    And they also follow "Evening Echoes" with "Dusk" at the end of Up Next
    And they've opened Poddle signed in

  Scenario: Reorder by dragging
    When they drag "Dusk" above "Breakfast in C"
    Then Up Next lists "Dusk", "Breakfast in C" then "Commute in D"
    And Up Next on the server is "Sunrise in A", "Dusk", "Breakfast in C" and "Commute in D"

  Scenario: Archive, then Undo puts it back in the same place
    When they archive "Breakfast in C" from its menu
    Then the Undo toast says "Archived"
    And Up Next lists "Commute in D" then "Dusk"
    When they press Undo
    Then Up Next lists "Breakfast in C", "Commute in D" then "Dusk"
    And "Breakfast in C" isn't archived

  Scenario: Remove with a swipe, then Undo
    When they swipe "Commute in D" left to remove it
    Then the Undo toast says "Removed"
    And Up Next lists "Breakfast in C" then "Dusk"
    When they press Undo
    Then Up Next lists "Breakfast in C", "Commute in D" then "Dusk"
    And Up Next on the server is "Sunrise in A", "Breakfast in C", "Commute in D" and "Dusk"

  Scenario: Mark played with a long swipe, then Undo
    When they swipe "Breakfast in C" all the way left to mark it played
    Then the Undo toast says "Played"
    And Up Next lists "Commute in D" then "Dusk"
    And "Breakfast in C" is played
    When they press Undo
    Then Up Next lists "Breakfast in C", "Commute in D" then "Dusk"
    And "Breakfast in C" isn't played
