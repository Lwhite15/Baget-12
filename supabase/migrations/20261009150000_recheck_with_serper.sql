-- Image search (Serper) is now on: give every listing without a photo another try.
update public.listings set image_checked_at = null where image_url is null;
