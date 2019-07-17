## kuso demo breaks all autosplitters (nasty bug)

When you quit _**kuso demo**_, it attempts to recursively delete the contents of %TEMP% folder (%LOCALAPPDATA%\Temp, usually C:\Users\name\AppData\Local\Temp) and if successful, it deletes the empty Temp folder.

LiveSplit cannot load autosplitters without the _**Temp**_ folder, so you have to stop kuso demo from deleting it.

## Here's one way to do it

1. If the Temp folder is already gone, create it manually.

2. Make a folder called "!!!!!!!!!!!!!!!!!!!!!!!!" _**inside**_ the Temp folder. Yes, just a bunch of exclamation points.\*

3. Right-click the !!!!!!!!!!!!!!!!!!!!!!!! folder -> Properties and follow the steps shown in this image (assuming you're using an admin account).

![folder permissions](https://github.com/neesi/autosplitters/raw/master/kuso_demo/permissions.png)

4. Try to delete the !!!!!!!!!!!!!!!!!!!!!!!! folder. You shouldn't be able to.

5. Download the splitter [here](https://raw.githubusercontent.com/neesi/autosplitters/master/kuso_demo/kuso_demo_livesplit.asl). <br><br>

\*kuso demo reads the contents of the Temp folder in a specific order. Folders first, exclamation point first. So by using many exclamation points you pretty much ensure that it'll be the first thing the game reads. After the first failed attempt to delete something, it'll give up and leave rest of the folders / files alone.