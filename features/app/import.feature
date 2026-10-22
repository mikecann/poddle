Feature: Moving from Overcast
  As someone switching from Overcast
  I want to import my Overcast export
  So my shows, my history and my queue come with me

  Scenario: Importing an Overcast export brings in the library, history and Up Next
    Given the listener has an account
    And they have an Overcast export on the phone
    And they've opened Poddle signed in
    When they import the Overcast export from Profile
    Then the import finishes
    And "Evening Echoes" is in their Library
    And "Morning Tones" is in their Library
    And "Priority Pings" is one of their past shows
    And "Sunrise in A" is played
    And Up Next on the server is "Twilight", "Breakfast in C" and "Commute in D"
