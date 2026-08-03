var emptyJsonUrl = "resources/report/empty.json";
var isSupportLocalFile = true;
//var valid_metrics = [0x100, 0x1, 0x200, 0x8, 0x20 | 0x40 | 0x80, 0x4, 0x10];
var valid_metrics = [0, 3, 4, 2, 5, 8, 9];
var valid_metrics_values = ['b', 'e', 't', 's', 'f', 'a', 'c'];

var isReplace = false;

if (!isDetachable) {
    $.ajax({
        type: "GET",
        url: emptyJsonUrl,
        contentType: "application/json; charset=utf-8",
        dataType: "json",
        beforeSend: function (xhr) {
            //if (checkLoginBeforeRequestExpired()){xhr.abort()};
            //xhr.setRequestHeader("Authorization", getAuthXToken());
        },
        success: function (data) {


        },
        error: function (jqXHR) {
            if (navigator.appName.indexOf("Chrome") > 0) {
                alert("Your Chrome browser" +
                    " blocks the report from reading data files.\nPlease stop all chrome processes and launch the Google Chrome browser from the command line window with the additional argument: \n'-allow-file-access-from-files'.\nE.g path to your chrome installation\chrome.exe --allow-file-access-from-files");
            } else {
                isReplace = confirm("Your browser" +
                    " blocks the report from reading data files.\nWould you like to turn off this limitation?");
            }
            isSupportLocalFile = false;

        },
        complete: function () {

        }

    });
}


$(document).ready(function () {


    var colorCheckbox = document.getElementById('colorSet');
    if (colorCheckbox != null && colorCheckbox != undefined) {
        colorCheckbox.checked = isRegularColor;
    } else {
        isRegularColor = true;
    }
    try {
        if (myLayout != null && myLayout != undefined) {
            myLayout.sizePane("north", 200);
        }
    } catch (e) {

    }

    if (isReplace == true) {
        location.replace("http://testingfreak.com/how-to-fix-cross-origin-request-security-cors-error-in-firefox-chrome-and-ie");
    }
});


var isRegularColor = $.cookie("colorSet") === "false" ? false : true;

function hideAll() {
    for (var i = 1; i < 6; ++i) {

        hideObj(document.getElementById('table' + i));
        hideObj(document.getElementById('filter' + i + '_div'));
    }

}

function hideObj(obj) {
    if (obj == null || obj == undefined) {
        return;
    }
    obj.style.visibility = 'hidden';
}


function changeColor() {
    // Check if the checkbox is checked
    var colorCheckbox = document.getElementById('colorSet');
    isRegularColor = colorCheckbox.checked ? true : false;
    $.cookie("colorSet", isRegularColor);
    initUI(true);

};

function checkColor() {

    document.getElementById('colorSet').checked = isRegularColor;
}

function getColor(gr) {
    if(isRegularColor == undefined) { //for any exception case
       isRegularColor = true;
    }
    return isRegularColor ? getRegularColors(gr) : getColorsBlind(gr);
}

function getRegularColors(gr) {
    var bgcolor = "#cccccc";
    if (gr == 0) bgcolor = "#ff6666";
    else if (gr < 29) bgcolor = "#ff9999";
    else if (gr < 50) bgcolor = "#ffcc99";
    else if (gr < 75) bgcolor = "#ffff66";
    else if (gr < 100) bgcolor = "#99ff66";
    else if (gr == 100) bgcolor = "#33cc00";
    return bgcolor;
}

function getColorsBlind(gr) {
    var bgcolor = "#f4f4f4";
    if (gr == 0) bgcolor = "#f4f4f4";
    else if (gr < 29) bgcolor = "#ffe800";
    else if (gr < 50) bgcolor = "#ffe800";
    else if (gr < 75) bgcolor = "#ffe800";
    else if (gr < 100) bgcolor = "#ffcccc";
    else if (gr == 100) bgcolor = "#3d6ab3";
    return bgcolor;
}

function getFontColor(gr) {
    var color = "#000000";
    if (gr == 0) color = "#000000";
    else if (gr < 29) color = "#3d6ab3";
    else if (gr < 50) color = "#3d6ab3";
    else if (gr < 75) color = "#3d6ab3";
    else if (gr < 100) color = "#000000";
    else if (gr == 100) color = "#ffe800";
    return color;
}

function bit_test(num, bit) {
    return ((num >> bit) % 2 != 0)
}

function getBitValues(val) {
    var numValue = (val == null) ? 0 : parseInt(val);
    if (numValue == 0) {
        return "- - - - - - - ";
    }
    var strValue = "";
    for (var i = 0; i < valid_metrics.length; i++) {
        if (bit_test(numValue, valid_metrics[i]) ||
            (valid_metrics[i] == 5 &&
                ((bit_test(numValue, 6)) || (bit_test(numValue, 7)) ))) {
            strValue += valid_metrics_values[i];
        } else {
            strValue += "-";
        }
        strValue += " ";
    }

    return strValue;

}

function getCell(event, data, name_column_number, isTermStr) {


    var node = data.node,
        $tdList = $(node.tr).find(">td"),
        cell,
        count = 0;
    var isExcluded = (data.node.data.excluded === "1");

    for (cell in data.node.data) {
        if (cell.toLowerCase().indexOf("items") >= 0) {
            return;
        }

        if (count == name_column_number) {    // 2 column is title!!
            $tdList.eq(count)[0].style.overflow = "hidden";
            $tdList.eq(count)[0].title = data.node.title;
            if (isExcluded) {
                $tdList.eq(count)[0].style.color = "#808080";
            }
            if (isTermStr === true && data.node.title != null && data.node.title != undefined) {
                $tdList.eq(count).html(getTableFromStrs(data.node.title.split(";"), data.node.data.vector_exclusions));
            }
            ++count;
        }

        if (isExcluded && isRegularColor && $tdList.eq(count)[0] != null && $tdList.eq(count)[0] != undefined) {
            $tdList.eq(count)[0].style.color = "#808080";

        }
        var val = data.node.data[cell];
        if (cell.toLowerCase().indexOf("grd") >= 0 || cell.toLowerCase().indexOf("cov") >= 0 || cell.toLowerCase().indexOf("grad") >= 0 || cell.toLowerCase().indexOf("(rank)") >= 0) {
            var numValue;
            if (val == null) {
                numValue = 0;
            } else {
                numValue = val.replace(/%/gi, ''); //remove %

                var indx = numValue.indexOf('(');
                if (indx > 0) {
                    numValue = numValue.substr(indx + 1, (numValue.indexOf(')') - indx - 1));
                }
            }
            if ($tdList.eq(count)[0] != null && $tdList.eq(count)[0] != undefined) {
                $tdList.eq(count)[0].style.backgroundColor = isExcluded ? "#cccccc" : getColor(numValue);
                if (!isRegularColor && !isExcluded) {
                    $tdList.eq(count)[0].style.color = getFontColor(numValue);
                }
            }
        } else if (cell.toLowerCase().indexOf("score") >= 0) {
            if (isExcluded) {
                if ($tdList.eq(count)[0] != null && $tdList.eq(count)[0] != undefined) {
                    $tdList.eq(count)[0].style.backgroundColor = "#cccccc";
                }

            } else {

                var numValue = (val == null) ? 0 : parseFloat(val);
                if ($tdList.eq(count)[0] != null && $tdList.eq(count)[0] != undefined) {
                    $tdList.eq(count)[0].style.backgroundColor = (val === 'X') ? "#cccccc" : getColor(numValue === 0 ? 0 : 100);
                    if (!isRegularColor) {
                        $tdList.eq(count)[0].style.color = (val === 'X') ? "#000000" : getFontColor(numValue === 0 ? 0 : 100);
                    }
                }
            }

        } else if (cell.toLowerCase().indexOf("status") >= 0 && cell.toLowerCase().indexOf("fault") < 0) {
            if ($tdList.eq(count)[0] != null && $tdList.eq(count)[0] != undefined) {
                $tdList.eq(count)[0].style.backgroundColor = getStatusColor(val);
            }

        } else if (cell.toLowerCase().indexOf("count tx to") >= 0) {
            if (val == "n/a") {
                val = "Ex";
            } else {

                var numValue = (val == null) ? 0 : parseInt(val);
                if (numValue < 0) {

                    switch (val) {
                        case "-1":
                            val = "Ex";
                            break;
                        case "-2":
                            val = "UNR";
                            break;
                        case "-3":
                            val = "U-EXCL";
                            break;
                        case "-4":
                            val = "Excluded to covered";
                            break;
                        case "-5":
                            val = "Excluded to uncovered";
                            break;
                        default:
                            val = "n/a";
                            break;
                    }
                }
            }
        } else if (cell.toLowerCase().indexOf("Open Office content") >= 0) {
            val = "<a href='" + val + "' target='_blank'>Show content</a>";
        } else if (cell.toLowerCase().indexOf("path") >= 0 || cell.toLowerCase().indexOf("file") >= 0 || cell.toLowerCase().indexOf("description") >= 0) {
            $tdList.eq(count)[0].style.wordWrap = "break-word";
            $tdList.eq(count)[0].style.wordBreak = "break-all";
            $tdList.eq(count)[0].style.minWidth = "200px";
            $tdList.eq(count)[0].style.maxWidth = "300px";
        } else if (val != null && cell.toLowerCase().indexOf("valid metrics") >= 0 && val.indexOf("-") < 0 && val.indexOf("n") < 0) {
            val = getBitValues(val);
        }
        if (val == "-1.0" || val == "-1") {
            val = "n/a";
        }

        if (val.toLowerCase() == "none") {
            val = "";
        }


        $tdList.eq(count).html(val);
        ++count;
    }
}

function getStatusColor(val) {
    var res = 0;
    switch (val) {
        case "passed":
        case "pass":
        case "proven":
        case "marked_proven":
        case "covered":
        case "ar_covered":
            res = 100;
            break;
        case "failed":
        case "fail":
        case "cex":
        case "ar_cex":
        case "unreachable":
            res = 0;
            break;
        default:
            res = 50;

    }
    return getColor(res);
}

function getTableFromStrs(ls, vector_exclusions) {

    if (ls.length == 0) {
        return "";
    }
    var w = 100 / ls.length;
    var res = [];
    res[res.length] = "<div width=100%><table width=100%><tr width=100%>";
    var isLong = (ls.length > 5);
    var startIndex = vector_exclusions == null || vector_exclusions == undefined || vector_exclusions.length == 0 ? ls.length+1 : ls.length - vector_exclusions.length;
    for (var i = 0; i < ls.length; ++i) {
        var s = ls[i];
        if (isLong && s.length > 11) {
            s = s.substr(0, 11) + "...";
        }
        if (vector_exclusions != null && vector_exclusions != undefined && i >= startIndex && vector_exclusions.charAt(i - startIndex) == 'E') {
            res[res.length] = "<td width=" + w + "%  align=center style=\"background-color:#cccccc\" title='" + ls[i] + "' >" + s + "</td>";
        }
        else {
            res[res.length] = "<td width=" + w + "%  align=center title='" + ls[i] + "' >" + s + "</td>";
        }

    }
    res[res.length] = "</tr></table></div>";

    return res.join("");
}



//filter
function implementFilter(inputObj, resetBtn, matchesLayer, treeTable) {
    inputObj.keyup(function (e) {
        if (e && e.which != $.ui.keyCode.ENTER) {
            return;
        }
        var n,

            match = $(this).val();

        if (e && e.which === $.ui.keyCode.ESCAPE || $.trim(match) === "") {
            resetBtn.click();
            return;
        }

        // Pass a string to perform case insensitive matching
        n = treeTable.filterNodes(match, false);

        resetBtn.attr("disabled", false);
        matchesLayer.text("(" + n + " matches)");
    }).focus();


    //reset filter
    resetBtn.click(function (e) {
        inputObj.val("");
        matchesLayer.text("");
        treeTable.clearFilter();
    }).attr("disabled", true);

    resetBtn.click();

}


//expand&Collapse all
function expandAll(isExpand, selector) {
    $(selector == undefined || selector == null ? "#treetable" : selector).fancytree("getRootNode").visit(function (node) {
        node.setExpanded(isExpand);
    });
}


//===============================================- Combined file support -================================================================

var reader;
var file;
var fileMap;

function showDiv(id, isVisible) {
    if (document.getElementById(id) != null) {
        document.getElementById(id).style.visibility = isVisible ? 'visible' : 'hidden';
    }
}


async function createFileFromUrl(url, fileName, mimeType) {
  const response = await fetch(url);
  const data = await response.blob();
  file = new File([data], fileName, { type: mimeType });
}


function mapFile() {
	var start = 0;
    var stop = 19;

    reader = new FileReader();
    var startIndex = -1;

    // If we use onloadend, we need to check the readyState.
    reader.onloadend = function (evt) {
        if (evt.target.readyState == FileReader.DONE) { // DONE == 2
            startIndex = parseInt(evt.target.result);
            readIndex(reader, file, startIndex, file.size);
        }
    };

    var blob = file.slice(start, stop + 1);
    reader.readAsBinaryString(blob);

}


function setDataFileMap() {

    var files = document.getElementById('files').files;
    if (!files.length) {
        alert('Please select a file!');
        return;
    } else {
        file = files[0];

        if(testName != undefined && file.name.indexOf(testName) < 0) {

            alert("You are trying to load a wrong " +
                file.name +
                " file. Select data_" +
                testName +
                ".report file from the report_data directory to open the report.");
            return;
        }

        showDiv('fileChoser', false);
        document.getElementById('fileChoser').innerHTML = "";

    }

    file = files[0];
    mapFile();
    showDiv('fileChoser', false);

}


function readBlob(opt_startByte, opt_stopByte) {

    var files = document.getElementById('files').files;
    if (!files.length) {
        alert('Please select a data.report  file!');
        return;
    }

    file = files[0];
    var start = parseInt(opt_startByte) || 0;
    var stop = parseInt(opt_stopByte) || file.size - 1;

    reader = new FileReader();
    var startIndex = -1;

    // If we use onloadend, we need to check the readyState.
    reader.onloadend = function (evt) {
        if (evt.target.readyState == FileReader.DONE) { // DONE == 2
            startIndex = parseInt(evt.target.result);
            readIndex(reader, file, startIndex, file.size);
        }
    };

    var blob = file.slice(start, stop + 1);
    reader.readAsBinaryString(blob);
}

function readIndex(reader, file, start, end) {
    reader.onloadend = function (evt) {
        if (evt.target.readyState == FileReader.DONE) { // DONE == 2
            try {
                fileMap = JSON.parse(evt.target.result);
            } catch (e) {
                fileMap = null;
            }
            if (fileMap == null) {
                alert("Read report data file failed. Please load correct data.report file. ");
            }
            else {
                initUI(false)
            }
        }
    };

    var blob = file.slice(start, end);
    reader.readAsBinaryString(blob);

}

function readFile(name, callBackFunction, isNewReader) {
    start = fileMap[name].start;
    end = fileMap[name].end;
    var output = null;

    var fileReader = isNewReader ? new FileReader() : reader;

    fileReader.onloadend = function (evt) {
        if (evt.target.readyState == FileReader.DONE) { // DONE == 2
            try {
            //we have to support utf-8 for Chinese and Japanese
                var res = evt.target.result;
            	var tmpJson = new TextDecoder("utf-8").decode(res);
                output = JSON.parse(tmpJson);
                //output = JSON.parse(evt.target.result);
            } catch (e) {
                output = [];
            }
            callBackFunction(output);
        }
    };

    var blob = file.slice(start, end);
    fileReader.readAsArrayBuffer(blob);

}



function showSubFoldersFromCombinedFile(fileName, data) {
    var start = fileMap[fileName].start;
    var end = fileMap[fileName].end;
    var output = null;
    var folderReader = new FileReader();
    folderReader.onloadend = function (evt) {
        if (evt.target.readyState == FileReader.DONE) { // DONE == 2

            try {
                output = JSON.parse(evt.target.result);
            } catch (e) {
                output = null;
            }

            if (output != null &&
                (data.node.children == undefined || data.node.children.length == 0)) {
                data.node.addChildren(output);
            }
        }
    };

    var blob = file.slice(start, end);
    folderReader.readAsBinaryString(blob);
}

//========================================= TREE with Icons support =========================================================
function getIconSrc(val, isRef) {
    if (isRef) {
        return val.indexOf("port") >= 0 ? "icon_ref_port.png" : "icon_ref_section.png";
    }
    return val.indexOf("port") >= 0 ? "icon_port.png" : (val.indexOf("perspective") >= 0 ? "icon_configuration.png" : "icon_section.png");
}

function getCell4Icons(event, data, name_column_number) {
    var node = data.node,
        $tdList = $(node.tr).find(">td"),
        cell,
        count = 0;

    for (cell in data.node.data) {
        if (count == name_column_number) {    // column is title!!
            $tdList.eq(count)[0].style.overflow = "hidden";
            $tdList.eq(count)[0].title = data.node.title;
            ++count;
        }
        var val = data.node.data[cell];
        $tdList.eq(0)[0].style.padding = "3px";
        if (cell.toLowerCase().indexOf("type") == 0) {  //type icon
            cell = "";
            var img_name = getIconSrc(val.toLowerCase(), val.toLowerCase().indexOf("referenced") >= 0);

            val = "<img src='resources/" + img_name + "' title ='" + val + "'  alt='" + val + "' />";
        } else if (cell.toLowerCase().indexOf("open office content") >= 0 && val) {
            val = "<a href='" + val + "' target='_blank'>Show</a>";
        }
        // if (cell.toLwerCase().indexOf("grd") >= 0 || cell.toLowerCase().indexOf("cov") >= 0 || cell.toLowerCase().indexOf("grad") >= 0) {

        if (val == "-1.0") {
            val = "n/a";
        }
        $tdList.eq(count).html(val);
        ++count;
    }
}


//========================================== TREE support============================================================
function hideUI() {
    // document.getElementById('treetable').style.display = 'block';
    document.getElementById('treetable').style.visibility = 'visible';
    document.getElementById('filter_div').style.visibility = 'visible';
    if (isDetachable) {
        document.getElementById('loading').innerHTML = "";
        document.getElementById('loading').style.visibility = 'hidden';
    } else {
        document.getElementById('loading').style.visibility = 'visible';
    }
}

function showLoading(isShow) {
    if (isDetachable) {
        showDiv('treetable', !isShow);
        showDiv('filter_div', !isShow);
    }
    showDiv('loading', isShow);
    if (!isShow) {
        document.getElementById('loading').innerHTML = ""; //to calculate  absolute position of tables
    } else {
        document.getElementById('treetable').style.display = 'block';
    }

}

function initTreeTable(input) {
    $("#treetable").fancytree({
        extensions: ["table", "filter"],
        quicksearch: true,
        checkbox: false,
        selectMode: 1,
        filter: {
            mode: "hide",
            autoApply: true
        },

        source: function (event, data) {
                return input;
            } ,
        lazyLoad: function (event, data) {
           // if (isDetachable) {
                showSubFoldersFromCombinedFile(data.node.data.sub_items, data);
                data.result = [];
            /*} else if (filesInZip > 0) {
                //====================
                showSubFolders(data.node.data.sub_items, data);
                data.result = [];
                //=====================
            } else {
                //alert("data.node.data.sub_items: " + data.node.data.sub_items) ;
                data.result = {url: data.node.data.sub_items};
            }*/
        },
        table: {
            indentation: 20,      // indent 20px per node level
            nodeColumnIdx: tree_table_name_column_index     // render the node title into the 0nd column
            //checkboxColumnIdx: 0  // render the checkboxes into the 1st column
        },

        renderColumns: function (event, data) {
            if (isReportWithIcons) {
                getCell4Icons(event, data, tree_table_name_column_index);
            } else {
                getCell(event, data, tree_table_name_column_index);
            }

        },
        icons: false, // Display node icons.
        focusOnSelect: true,
        postProcess: function (event, data) {

            postLoadAction(false);
            selectNode();

        },
        activate: function (event, data) {
            activeTreeItemAction(event, data);
        }
    });
    var tree_table = $("#treetable").fancytree("getTree");
    implementFilter($("input[name=search1]"), $("button#btnResetSearch1"), $("span#matches1"), tree_table);


    postLoadAction(false);
    selectNode();

}
//=================set initial selection from query string==================================

var urlParams;
var initialSelectionPath = null;
function initURLParams() {

    var match,
        pl     = /\+/g,  // Regex for replacing addition symbol with a space
        search = /([^&=]+)=?([^&]*)/g,
        decode = function (s) { return decodeURIComponent(s.replace(pl, " ")); },
        query  = window.location.search.substring(1);

    urlParams = {};
    while (match = search.exec(query))
       urlParams[decode(match[1])] = decode(match[2]);

}

var count = 0;
var selNode = null;
function selectNode() {
	initURLParams();
	var path = urlParams["path"];//"Verification Metrics.Types.decoder";
	if(path == undefined)
		return;

	var nodes = path.split("/");
	if(nodes.length == 0){
		return;
		}

		var tree_table = $("#treetable").fancytree("getTree");

		try{
            selNode = tree_table.getRootNode();
        } catch(e) {
            tree_table = $("#test_tree_table").fancytree("getTree");
            selNode = tree_table.getRootNode();
        }
		if(selNode.children.length > 0 &&
		    selNode.children[0].title.indexOf("Load") >=0
		    && count < 20) {
			setTimeout(selectNode, 1000);
			count++;
			return;
		}

		for(i =0; i < nodes.length && selNode != null; i++){
			var name = nodes[i].replace(/%2f/gi, '/').replace(/%26/gi, '&');;
			for(j=0; j < selNode.children.length; j++){
				var node = selNode.children[j];
				if(node.title == name) {
					selNode = node;
					 node.setExpanded(true);
					break;
				}
			}


		}

		if(selNode == null) { //id don't find the path, try to find the last element
			tree_table.findFirst(nodes[nodes.length -1]);
		}

		if(selNode != null){
			selNode.setSelected(true);
			selNode.span.scrollIntoView(false);
			selNode.setActive(true);

		}


}

///=========================================================================================

function addFileChooserHandler() {
    if (isDetachable) {

        document.getElementById('files').addEventListener('change', function (evt) {

            setDataFileMap();

        }, true);
    }

}

function readTreeDataFromFile() {
    var start = fileMap["tree.json"].start;
    var end = fileMap["tree.json"].end;

    reader.onloadend = function (evt) {
        if (evt.target.readyState == FileReader.DONE) { // DONE == 2
            initTreeTable(JSON.parse(evt.target.result));//;, false);
        }
    };

    var blob = file.slice(start, end);
    reader.readAsBinaryString(blob);
}

function emptyFunction() {

}

function emptyFunction(p1, p2) {

}

var table_data = null;

function diff_table(input, id, indx, activeFunction, postLoadFunction, isTerm) {
    table_data = input;
    // Attach the fancytree widget to an existing <div id="tree"> element
    // and pass the tree options as an argument to the fancytree() function:
    try {
        $(id).fancytree({
            extensions: ["table", "filter"],
            quicksearch: true,
            checkbox: false,
            filter: {
                mode: "hide",
                autoApply: true
            },
            source: //isDetachable ?
                function (event, data) {
                    return table_data;//get source call sometime is coming fron fancytree lid with the old data,so we need to keep and send the actuaal data here
                } /*: {
                    url: input,
                    cache: true
                }*/,

            lazyLoad: function (event, data) {
                data.result = []
            },

            table: {
                indentation: 0,      // indent 20px per node level
                nodeColumnIdx: indx   // render the node title into the 0nd column
                //checkboxColumnIdx: 0  // render the checkboxes into the 1st column
            },

            renderColumns: function (event, data) {
                getCell(event, data, indx, isTerm);

            },
            activate: function (event, data) {
                activeFunction(event, data);
            },

            postProcess: function (event, data) {
                postLoadFunction(false);
            },
            icons: false, // Display node icons.
            focusOnSelect: true

        });
    } catch (e) {

    }

    postLoadFunction(false);
}

function loadTopTable(input) {
    diff_table(input,
        "#table1",
        table1_title_index,
        selectTopTableItem, postLoadFunction);

    implementFilter($("input[name=search1]"), $("button#btnResetSearch1"), $("span#matches1"), $("#table1").fancytree("getTree"));
}

function loadSecondTable(input) {
    diff_table(input,
        "#table2",
        table2_title_index,
        emptyFunction, emptyFunction);

    implementFilter($("input[name=search2]"), $("button#btnResetSearch2"), $("span#matches2"), $("#table2").fancytree("getTree"));
}

