Feature: New episodes
  As a listener
  I want new episodes to land in Up Next the way each show is set up
  So the shows I care about most are always first

  Background:
    Given the listener follows "Morning Tones" with "Sunrise in A" and "Breakfast in C" in Up Next
    And they've opened Poddle signed in

  Scenario: A new episode from a normal show goes to the bottom of Up Next
    When "Morning Tones" publishes "Lunch in E"
    Then Up Next lists "Breakfast in C" then "Lunch in E"

  Scenario: A show set to "Up Next top" puts it at the top
    When they set new episodes from "Morning Tones" to "Up Next top"
    And "Morning Tones" publishes "Lunch in E"
    Then Up Next lists "Lunch in E" then "Breakfast in C"

  Scenario: A show set to "Don't add" leaves Up Next alone
    When they set new episodes from "Morning Tones" to "Don't add"
    And "Morning Tones" publishes "Lunch in E"
    Then the page for "Morning Tones" lists "Lunch in E"
    And Up Next lists "Breakfast in C"
