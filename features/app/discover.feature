Feature: Episodes from shows you don't follow
  As a listener
  I want to find an episode by name and get just that one
  So I can hear it without following the whole show

  Background:
    Given the listener has an account
    And they don't auto-download
    And they've opened Poddle signed in

  Scenario: Find an episode by name and download just that one
    When they search Discover for "breakfast"
    And they open the episode "Breakfast in C" from the results
    And they download it from its page
    Then Up Next lists "Breakfast in C"
    And "Breakfast in C" shows as downloaded
    And they still don't follow "Morning Tones"

  Scenario: Look at a show's episodes before following it
    When they search Discover for "tones"
    And they open "Morning Tones" from the results
    Then its page lists "Commute in D", "Breakfast in C" and "Sunrise in A"
    And its page offers to follow it
