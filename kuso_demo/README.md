## LOVE 2: kuso (Demo) breaks all auto splitters

***edit**: the splitter now patches the %TEMP% deletion bug (you have to always load the splitter before closing the game), but you should still create the "!!!!!!!!!!!!!!!!!!!!!!!!" folder as described below.* <br><br>

When exiting ***kuso demo***, it attempts to recursively delete the contents of %TEMP% folder (%LOCALAPPDATA%\Temp, usually C:\Users\name\AppData\Local\Temp) and if successful, it deletes the empty Temp folder.

LiveSplit cannot load auto splitters without the ***Temp*** folder, so you have to stop kuso demo from deleting it.

## Here's one way to do it

1. If the Temp folder is already gone, create it manually.

2. Make a folder called "!!!!!!!!!!!!!!!!!!!!!!!!" ***inside*** the Temp folder. Yes, just a bunch of exclamation points.\*

3. Right-click the !!!!!!!!!!!!!!!!!!!!!!!! folder -> Properties and follow the steps shown in this image (assuming you're using an admin account).

![folder permissions](https://github.com/neesi/autosplitters/raw/master/kuso_demo/permissions.png)

4. Try to delete the !!!!!!!!!!!!!!!!!!!!!!!! folder. You shouldn't be able to.

5. Note that the !!!!!!!!!!!!!!!!!!!!!!!! folder might still get deleted when updating Windows, for example.

6. Restart LiveSplit and load the splitter. <br><br>

\*kuso demo reads the contents of the Temp folder in a specific order. Folders first, exclamation point first. So by using many exclamation points you pretty much ensure that it'll be the first thing the game reads. After the first failed attempt to delete something, it'll give up and leave rest of the folders / files alone.
