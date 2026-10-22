Feature: Following shows
  As a listener
  I want to find shows and follow them
  So their episodes are in my library

  Background:
    Given the listener has an account
    And they've opened Poddle signed in

  Scenario: Search Discover and follow a show
    When they search Discover for "tones"
    And they follow "Morning Tones" from the results
    Then "Morning Tones" is in their Library
    And the page for "Morning Tones" lists "Commute in D", "Breakfast in C" and "Sunrise in A"

  Scenario: Add a show by pasting its feed URL
    When they paste the feed URL for "Evening Echoes" into Discover's URL field
    Then Discover says "Following Evening Echoes"
    And "Evening Echoes" is in their Library

  Scenario: Unsubscribe, then Undo
    Given the listener follows "Morning Tones"
    When they unsubscribe from "Morning Tones" on its page
    Then the Undo toast says "Unsubscribed"
    And they don't follow "Morning Tones" any more
    When they press Undo
    Then they follow "Morning Tones" again


  Scenario: Back from a show's page returns to the Library
    Given the listener follows "Morning Tones"
    When they open the page for "Morning Tones"
    And they tap "< Library"
    Then they're back on the Library with "Morning Tones"
