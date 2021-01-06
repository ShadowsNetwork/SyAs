const path = require('path');

module.exports = {
	entry: './index.js',
	output: {
		filename: 'browser.js',
		path: path.resolve(__dirname),
		library: 'syas',
		libraryTarget: 'umd',
	},
};