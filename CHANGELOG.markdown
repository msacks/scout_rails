# 0.0.3.pre

* Removed dynamic ActiveRecord caller instrumentation
* Fixed issue that prevents the app from loading if ActiveRecord isn't used.
* Using a metric hash for each request, then merging when complete. Ensures data associated w/requests that overlap a 
  minute boundary are correctly associated.

# 0.0.2

Doesn't prevent app from loading if no configuration exists for the current environment.

# 0.0.1

Boom! Initial Release.